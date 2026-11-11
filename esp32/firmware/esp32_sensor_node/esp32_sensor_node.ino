// ============================================================================
//  esp32_sensor_node.ino - ESP32 sensor node for the Sui-OM2M testbed (v2)
//
//  v1 (Hamza AlCharif's original) connected to ONE broker IP and stayed there, so
//  if that Pi went down the sensor was lost. v2 treats the cluster as the
//  unit (DESIGN.md):
//
//    1. Joins WiFi.
//    2. Connects to the first healthy broker of the cluster: its home node
//       first, then the others (cluster.h). A broker that fails is skipped for
//       a bounded, growing backoff and the next one is tried at once.
//    3. Learns cluster membership from the retained topic
//         om2m/cluster/brokers         (published by every Pi's bridge)
//       so nodes added later are used without a reflash.
//    4. Every PUBLISH_INTERVAL_MS takes one reading, numbers it
//         (epoch, seq)   epoch: +1 on every power-up, kept in NVS
//                        seq:   +1 per reading, never reset by a reconnect
//       and publishes it to  sensors/<DEVICE_ID>/telemetry.
//       A bridge acknowledges EACH stored reading on sensors/<DEVICE_ID>/ack.
//       Readings without an ack are kept and re-sent after a (re)connect; the
//       bridges drop duplicates.
//    5. Presence on sensors/<DEVICE_ID>/status: retained "online" per
//       connection, Last Will "offline". Both carry a session id
//       "<epoch>.<n>", so a late Last Will from a broker the sensor has left
//       can never mark it offline while it is online elsewhere.
//    6. Returns to its home broker only after home has been reachable for
//       HOME_STABLE_MS (hysteresis), leaving the other broker cleanly (no
//       Last Will) and clearing its retained presence there.
//
//    8. (v2.2) Trusts only SIGNED acks: a reading leaves the resend buffer
//       only on an ack for (DEVICE_ID, epoch, seq) signed by a pinned bridge
//       ack key (config.h ACK_TRUSTED_KEYS). Forged acks are ignored and do
//       not hold off the no-ack failover.
//
//    7. (v2.1) Has its OWN on-chain identity: an Ed25519 key generated on the
//       device (device_key.h). Every telemetry/status message, including the
//       Last Will, carries "pk" and is signed ("sig"); the bridges accept it
//       only if that key's Sui address is registered for DEVICE_ID in the
//       on-chain identity registry (role AE), so readings cannot be forged by
//       anyone else on the network, and a council vote can revoke the device.
//
//  What it does NOT do: speak oneM2M or send Sui transactions. The Pi-side bridge
//  (pi/om2m_ipe_bridge.py) turns these MQTT messages into OM2M resources.
//  Sensor data stays off-chain (SY1).
//
//  Libraries (Arduino Library Manager):
//    - PubSubClient by Nick O'Leary
//    - DHT sensor library by Adafruit (+ Adafruit Unified Sensor)
//  Board: "ESP32 Dev Module" (esp32 core by Espressif). Preferences and
//  libsodium (sodium.h) are part of the core.
// ============================================================================

#include <WiFi.h>
#include <PubSubClient.h>
#include <Preferences.h>
#include <time.h>
#include "config.h"
#include "cluster.h"
#include "device_key.h"

#if ENABLE_DHT
#include <DHT.h>
DHT dht(DHT_PIN, DHT_TYPE);
#endif

WiFiClient   net;
PubSubClient mqtt(net);
Preferences  prefs;
cluster::Selector sel;

// ---- topics / identity (built once in setup) --------------------------------
static char topicTelemetry[96];
static char topicStatus[96];
static char topicAck[96];
static const char* TOPIC_BROKERS = "om2m/cluster/brokers";
static char bootId[9];               // random per power-up (lets the Pi spot an NVS reset)
static uint32_t epoch = 0;           // +1 per power-up, persisted in NVS
static uint32_t connCount = 0;       // connections in this epoch
static char session[24];             // "<epoch>.<connCount>"
static char lwtPayload[320];

// ---- readings and the resend buffer -----------------------------------------
#define PAYLOAD_LEN 640
struct Slot { uint32_t seq; bool used; bool acked; char payload[PAYLOAD_LEN]; };
static Slot slots[RESEND_SLOTS];
static uint32_t seqNo = 0;           // next sequence number
static uint32_t connStartSeq = 0;    // first seq published on the current connection
static uint32_t resendCursor = 0;
static bool resendActive = false;
static unsigned long ackWaitUntil = 0;
static unsigned long firstUnackedPubMs = 0;   // first publish since the last ack (0 = none)

// ---- state ------------------------------------------------------------------
static unsigned long lastReadingMs   = 0;
static unsigned long wifiLostSinceMs = 0;
static unsigned long nextAttemptMs   = 0;
static bool ntpStarted = false;

// -----------------------------------------------------------------------------
static void blink(int times, int ms) {
  for (int i = 0; i < times; i++) {
    digitalWrite(STATUS_LED_PIN, HIGH); delay(ms);
    digitalWrite(STATUS_LED_PIN, LOW);  delay(ms);
  }
}

static void connectWifi() {
  Serial.printf("[wifi] connecting to %s", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 20000UL) {
    delay(500);
    Serial.print(".");
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("\n[wifi] connected, ip=%s rssi=%d\n",
                  WiFi.localIP().toString().c_str(), (int)WiFi.RSSI());
  } else {
    Serial.println("\n[wifi] not connected yet, will keep retrying");
  }
}

static void startNtpOnce() {
  if (ntpStarted || WiFi.status() != WL_CONNECTED) return;
  configTime(0, 0, NTP_SERVER);      // UTC; the Pi converts if needed
  ntpStarted = true;
}

// Unix seconds, or 0 if NTP has not synced (anything before 2024 counts as unsynced)
static uint32_t unixTime() {
  time_t now = time(nullptr);
  return (now > 1704067200) ? (uint32_t)now : 0;
}

// ---- incoming: cluster membership and acks ----------------------------------
static void onMessage(char* topic, byte* payload, unsigned int len) {
  char buf[512];
  if (len >= sizeof(buf)) return;
  memcpy(buf, payload, len);
  buf[len] = 0;
  if (strcmp(topic, TOPIC_BROKERS) == 0) {
    int k = sel.learn(buf, CLUSTER_ALLOW_PREFIX);
    Serial.printf("[cluster] membership update: %d entries, %d known brokers\n", k, sel.n);
    return;
  }
  if (strcmp(topic, topicAck) == 0) {
    unsigned long e = 0, s = 0;
#if REQUIRE_SIGNED_ACKS
    static char body[512];
    char idField[80];
    snprintf(idField, sizeof(idField), "\"id\":\"%s\"", DEVICE_ID);
    if (!devkey::verifyAck(buf, len, body, sizeof(body)) || !strstr(body, idField)) {
      if (devkey::acksRejected++ % 20 == 0)
        Serial.printf("[ack] ignored an unsigned/forged ack (%lu so far)\n",
                      (unsigned long)devkey::acksRejected);
      return;
    }
    const char* src = body;
#else
    const char* src = buf;
#endif
    const char* pe = strstr(src, "\"epoch\":");
    const char* ps = strstr(src, "\"seq\":");
    if (!pe || !ps) return;
    e = strtoul(pe + 8, nullptr, 10);
    s = strtoul(ps + 6, nullptr, 10);
    if (e != epoch) return;          // an ack from an earlier power-up
    Slot& sl = slots[s % RESEND_SLOTS];
    if (sl.used && sl.seq == s) sl.acked = true;
    firstUnackedPubMs = 0;           // a bridge is alive behind this broker
  }
}

// ---- connecting -------------------------------------------------------------
static bool connectTo(int i) {
  const cluster::Broker& br = sel.b[i];
  const char* user = (strlen(MQTT_USER) > 0) ? MQTT_USER : nullptr;
  const char* pass = (strlen(MQTT_PASS) > 0) ? MQTT_PASS : nullptr;
  unsigned long now = millis();

  // TCP first, with a bounded timeout: PubSubClient's own connect() has none.
  if (!net.connect(br.host, br.port, CONNECT_TIMEOUT_MS)) {
    Serial.printf("[mqtt] %s (%s:%u) unreachable\n", br.label, br.host, br.port);
    sel.onFailed(i, now);
    return false;
  }
  connCount++;
  snprintf(session, sizeof(session), "%lu.%lu", (unsigned long)epoch, (unsigned long)connCount);
  snprintf(lwtPayload, sizeof(lwtPayload),
           "{\"state\":\"offline\",\"id\":\"%s\",\"pk\":\"%s\",\"session\":\"%s\"}",
           DEVICE_ID, devkey::pkHex, session);
  devkey::signJson(lwtPayload, sizeof(lwtPayload));   // signed now: the broker sends it later
  mqtt.setServer(br.host, br.port);
  // Client ID = DEVICE_ID so two boards never kick each other off a broker.
  if (!mqtt.connect(DEVICE_ID, user, pass, topicStatus, 1, true, lwtPayload)) {
    Serial.printf("[mqtt] %s refused, state=%d\n", br.label, mqtt.state());
    net.stop();
    sel.onFailed(i, now);
    return false;
  }
  sel.onConnected(i, now);

  char online[512];
  snprintf(online, sizeof(online),
           "{\"state\":\"online\",\"id\":\"%s\",\"pk\":\"%s\",\"session\":\"%s\",\"epoch\":%lu,"
           "\"boot\":\"%s\",\"fw\":\"%s\",\"ip\":\"%s\",\"home\":\"%s\",\"broker\":\"%s\"}",
           DEVICE_ID, devkey::pkHex, session, (unsigned long)epoch, bootId, FW_VERSION,
           WiFi.localIP().toString().c_str(), HOME_NODE, br.label);
  devkey::signJson(online, sizeof(online));
  mqtt.publish(topicStatus, online, true);   // retained presence for THIS session
  mqtt.subscribe(TOPIC_BROKERS, 1);
  mqtt.subscribe(topicAck, 1);
  // After ACK_WAIT_MS, re-send every reading from before this connection that
  // no bridge has acknowledged (taken while offline, or lost with the broker).
  connStartSeq = seqNo;
  firstUnackedPubMs = 0;
  ackWaitUntil = millis() + ACK_WAIT_MS;
  resendActive = false;
  Serial.printf("[mqtt] connected to %s (%s:%u) as %s session %s\n",
                br.label, br.host, br.port, DEVICE_ID, session);
  blink(2, 80);
  return true;
}

// Planned move (back home): clear our retained presence here and leave with a
// clean DISCONNECT, so this broker never fires our Last Will.
static void leaveCleanly() {
  mqtt.publish(topicStatus, (const uint8_t*)"", 0, true);
  mqtt.disconnect();
  net.stop();
  sel.onDisconnectedCleanly();
}

static bool probeHome() {
  WiFiClient probe;
  const cluster::Broker& h = sel.b[sel.home];
  bool ok = probe.connect(h.host, h.port, CONNECT_TIMEOUT_MS);
  probe.stop();
  return ok;
}

// ---- readings -----------------------------------------------------------------
// Builds one telemetry JSON object. Returns false if no sensor produced a value.
static bool buildReading(char* out, size_t cap, uint32_t seq) {
  const char* via = (sel.current >= 0) ? sel.b[sel.current].label : "";
  int n = snprintf(out, cap,
                   "{\"v\":2,\"id\":\"%s\",\"pk\":\"%s\",\"epoch\":%lu,\"boot\":\"%s\",\"seq\":%lu,"
                   "\"ts\":%lu,\"up_ms\":%lu,\"rssi\":%d,\"via\":\"%s\"",
                   DEVICE_ID, devkey::pkHex, (unsigned long)epoch, bootId, (unsigned long)seq,
                   (unsigned long)unixTime(), (unsigned long)millis(), (int)WiFi.RSSI(), via);
  bool any = false;

#if ENABLE_DHT
  float t = dht.readTemperature();
  float h = dht.readHumidity();
  if (isnan(t) || isnan(h)) {          // DHT11 misses a read now and then: retry once
    delay(1100);
    t = dht.readTemperature();
    h = dht.readHumidity();
  }
  if (!isnan(t) && !isnan(h)) {
    n += snprintf(out + n, cap - n, ",\"temperature\":%.1f,\"humidity\":%.1f", t, h);
    any = true;
  } else {
    n += snprintf(out + n, cap - n, ",\"dht_ok\":false");
    Serial.println("[dht] read failed twice; check wiring (VCC 3.3V, DATA->GPIO4, GND)");
  }
#endif

#if ENABLE_LDR
  int raw = analogRead(LDR_PIN);       // 0..4095 (12-bit)
  int pct = (int)((raw * 100L) / 4095L);
  n += snprintf(out + n, cap - n, ",\"light_raw\":%d,\"light_pct\":%d", raw, pct);
  any = true;
#endif

  snprintf(out + n, cap - n, "}");
  // Unsigned readings are rejected by every bridge, so do not keep one.
  return any && devkey::signJson(out, cap);
}

static void takeReading() {
  Slot& s = slots[seqNo % RESEND_SLOTS];
  if (!buildReading(s.payload, sizeof(s.payload), seqNo)) return;
  s.seq = seqNo;
  s.used = true;
  s.acked = false;
  uint32_t seq = seqNo++;
  if (mqtt.connected()) {
    bool ok = mqtt.publish(topicTelemetry, s.payload, false);
    if (ok && !firstUnackedPubMs) firstUnackedPubMs = millis();
    Serial.printf("[pub] %s seq=%lu %s\n", ok ? "ok " : "ERR", (unsigned long)seq, s.payload);
    if (ok) { digitalWrite(STATUS_LED_PIN, HIGH); delay(30); digitalWrite(STATUS_LED_PIN, LOW); }
  } else {
    Serial.printf("[buf] seq=%lu kept for resend (not connected)\n", (unsigned long)seq);
  }
}

// Re-sends unacknowledged readings from before this connection, a few per pass.
static void resendSome() {
  if (!resendActive || !mqtt.connected()) return;
  for (int k = 0; k < 8 && resendCursor < connStartSeq; resendCursor++) {
    const Slot& s = slots[resendCursor % RESEND_SLOTS];
    if (!s.used || s.seq != resendCursor || s.acked) continue;   // overwritten or confirmed
    mqtt.publish(topicTelemetry, s.payload, false);
    Serial.printf("[resend] seq=%lu\n", (unsigned long)resendCursor);
    k++;
  }
  if (resendCursor >= connStartSeq) resendActive = false;
}

// -----------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  delay(1500);
  pinMode(STATUS_LED_PIN, OUTPUT);
#if ENABLE_LDR
  analogReadResolution(12);
  pinMode(LDR_PIN, INPUT);
#endif
#if ENABLE_DHT
  dht.begin();
#endif

  prefs.begin("sui-esp32", false);
  epoch = prefs.getUInt("epoch", 0) + 1;
  prefs.putUInt("epoch", epoch);
  prefs.end();

  snprintf(bootId, sizeof(bootId), "%08lx", (unsigned long)esp_random());
  snprintf(topicTelemetry, sizeof(topicTelemetry), "sensors/%s/telemetry", DEVICE_ID);
  snprintf(topicStatus,    sizeof(topicStatus),    "sensors/%s/status",    DEVICE_ID);
  snprintf(topicAck,       sizeof(topicAck),       "sensors/%s/ack",       DEVICE_ID);

  sel.p.backoffBaseMs = BACKOFF_BASE_MS;
  sel.p.backoffMaxMs  = BACKOFF_MAX_MS;
  sel.p.homeProbeMs   = HOME_PROBE_MS;
  sel.p.homeStableMs  = HOME_STABLE_MS;
  sel.addSeeds(CLUSTER_SEEDS);
  if (!sel.setHome(HOME_NODE)) Serial.printf("[cluster] HOME_NODE %s is not in CLUSTER_SEEDS\n", HOME_NODE);

  Serial.printf("\n[boot] %s fw=%s epoch=%lu boot=%s brokers=%d home=%s\n", DEVICE_ID, FW_VERSION,
                (unsigned long)epoch, bootId, sel.n, HOME_NODE);

  connectWifi();                     // radio on: the hardware RNG is now truly random
  if (!devkey::init("sui-esp32-id")) Serial.println("[id] libsodium init FAILED");
  Serial.printf("[id] device key pk=%s sui_address=%s\n"
                "[id] register: scripts/v9/council.sh propose <member> id-register %s %s 3\n",
                devkey::pkHex, devkey::addrHex, devkey::addrHex, DEVICE_ID);
  {
    int k = devkey::loadAckKeys(ACK_TRUSTED_KEYS);
    Serial.printf("[ack] %d pinned bridge ack key(s); signed acks %s\n", k,
                  REQUIRE_SIGNED_ACKS ? "required" : "NOT required");
    if (REQUIRE_SIGNED_ACKS && k == 0)
      Serial.println("[ack] WARNING: no ACK_TRUSTED_KEYS: no ack will be accepted (run gen_ack_keys.sh)");
  }
  startNtpOnce();
  mqtt.setBufferSize(1024);
  mqtt.setKeepAlive(MQTT_KEEPALIVE_S);
  mqtt.setSocketTimeout(2);
  mqtt.setCallback(onMessage);
}

void loop() {
  unsigned long now = millis();

  // ---- readings are taken whatever the connection state (buffered for resend)
  if (lastReadingMs == 0 || now - lastReadingMs >= PUBLISH_INTERVAL_MS) {
    lastReadingMs = now;
    takeReading();
  }

  // ---- WiFi watchdog --------------------------------------------------------
  if (WiFi.status() != WL_CONNECTED) {
    if (wifiLostSinceMs == 0) {
      wifiLostSinceMs = now;
      Serial.println("[wifi] lost, reconnecting");
      WiFi.reconnect();
    }
    if (now - wifiLostSinceMs > WIFI_RESTART_AFTER_MS) {
      Serial.println("[wifi] down too long, restarting");
      ESP.restart();
    }
    delay(200);
    return;
  }
  wifiLostSinceMs = 0;
  startNtpOnce();

  // ---- MQTT: fail over across the cluster ------------------------------------
  if (!mqtt.connected()) {
    if (sel.current >= 0) {          // we were connected: this broker just failed
      Serial.printf("[mqtt] lost %s (state=%d), failing over\n", sel.b[sel.current].label, mqtt.state());
      net.stop();
      sel.onFailed(sel.current, now);
    }
    if (now >= nextAttemptMs) {
      int i = sel.next(now);
      if (i >= 0) {
        if (!connectTo(i)) nextAttemptMs = 0;      // try the next candidate straight away
      } else {
        unsigned long w = sel.waitMs(now);
        nextAttemptMs = now + (w < 250 ? 250 : (w > 5000 ? 5000 : w));
      }
    }
    delay(20);
    return;
  }
  mqtt.loop();

  // ---- after (re)connecting: resend what no bridge has confirmed --------------
  if (ackWaitUntil && now >= ackWaitUntil) {
    ackWaitUntil = 0;
    resendActive = true;
    resendCursor = connStartSeq > RESEND_SLOTS ? connStartSeq - RESEND_SLOTS : 0;
  }
  resendSome();

  // ---- broker up but nothing acknowledged: its bridge is down -> fail over ----
  // (millis(), not `now`: a DHT retry inside takeReading() may have advanced the
  // clock past `now`, and the unsigned difference would wrap.)
  if (firstUnackedPubMs && millis() - firstUnackedPubMs >= NO_ACK_FAILOVER_MS) {
    Serial.printf("[mqtt] no acks via %s for %lus: its bridge is down, failing over\n",
                  sel.b[sel.current].label, (unsigned long)(NO_ACK_FAILOVER_MS / 1000));
    int cur = sel.current;
    mqtt.disconnect();               // clean: the next session's "online" supersedes this one
    net.stop();
    sel.penalize(cur, millis(), 3 * NO_ACK_FAILOVER_MS);   // keep out, also from the home return
    firstUnackedPubMs = 0;
    nextAttemptMs = 0;
    return;
  }

  // ---- return home with hysteresis --------------------------------------------
  if (sel.probeDue(now)) sel.onHomeProbe(probeHome(), now);
  if (sel.shouldReturnHome(now)) {
    Serial.printf("[cluster] home %s stable for %lus: moving back\n", HOME_NODE,
                  (unsigned long)(HOME_STABLE_MS / 1000));
    leaveCleanly();
    nextAttemptMs = 0;
  }
}
