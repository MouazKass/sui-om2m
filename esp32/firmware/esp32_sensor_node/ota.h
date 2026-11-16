// ============================================================================
//  ota.h - signed over-the-air firmware updates (fw 2.4)
//
//  Only the FIRST flash needs USB. After that a release is published once
//  (scripts/ota/publish.sh) and every board updates itself:
//
//    1. It learns of a release from the retained, signed MQTT announce
//         om2m/ota/manifest
//       (sent on every (re)connect), and also polls
//         http://<current broker>:OTA_PORT/fw/manifest.json  every OTA_CHECK_MS.
//       <current broker> is the cluster address 192.168.1.250, so the image
//       comes from whichever Pi holds it; every Pi runs pi/ota_server.py.
//    2. ota_core.h verifies the manifest (pinned firmware key, this device,
//       newer than installed and than any failed release, fits a slot).
//    3. It streams the image into the OTHER app slot (Update.h) while hashing
//       it, and switches the boot slot only if size and SHA-256 match.
//    4. The new image boots on trial. It is kept only once it has connected and
//       received a SIGNED bridge ack (ota::onHealthy); if it fails to get there
//       within OTA_MAX_TRIES boots (crash, no Wi-Fi, no cluster), the board
//       switches back to the previous slot and never retries that version.
//
//  Nothing on the network is trusted: a forged, old, tampered or truncated
//  release is refused, so the server or anyone on the Wi-Fi can at worst
//  withhold an update. Progress goes to the serial log and, signed with the
//  device key, to sensors/<DEVICE_ID>/ota.
// ============================================================================
#pragma once
#include "ota_core.h"

#ifndef OTA_ENABLE
#define OTA_ENABLE 1
#endif
#ifndef OTA_PORT
#define OTA_PORT 8070
#endif
#ifndef OTA_CHECK_MS
#define OTA_CHECK_MS (6UL * 3600UL * 1000UL)   // poll fallback; the announce is immediate
#endif
#ifndef OTA_RETRY_MS
#define OTA_RETRY_MS 60000UL                   // after a failed download
#endif
#ifndef OTA_HTTP_TIMEOUT_MS
#define OTA_HTTP_TIMEOUT_MS 8000UL             // per read stall
#endif
static const char* OTA_TOPIC = "om2m/ota/manifest";

#if OTA_ENABLE && !FW_HOSTCHECK
#include <Update.h>
#include <esp_ota_ops.h>

// Keep a freshly installed image in the bootloader's "pending verify" state
// (where the core supports it) until ota::onHealthy() confirms it.
extern "C" bool verifyRollbackLater() { return true; }

namespace otadev {
static ota::State st;
static ota::Manifest cand;
static bool candReady = false;
static unsigned long nextPollMs = 0, retryAfterMs = 0;
static char lastReason[32] = "";
static PubSubClient* mq = nullptr;
static char otaTopic[96];

static void report(const char* state, uint32_t version, const char* reason) {
  Serial.printf("[ota] %s v%lu%s%s\n", state, (unsigned long)version, reason ? " " : "", reason ? reason : "");
  if (!mq || !mq->connected()) return;
  char msg[384];
  snprintf(msg, sizeof(msg),
           "{\"id\":\"%s\",\"pk\":\"%s\",\"ota\":\"%s\",\"version\":%lu,\"installed\":%lu,\"reason\":\"%s\"}",
           DEVICE_ID, devkey::pkHex, state, (unsigned long)version, (unsigned long)st.ver,
           reason ? reason : "");
  devkey::signJson(msg, sizeof(msg));
  mq->publish(otaTopic, msg, false);
}

// Call once in setup(), right after the device key is ready.
static void begin(PubSubClient& m) {
  mq = &m;
  snprintf(otaTopic, sizeof(otaTopic), "sensors/%s/ota", DEVICE_ID);
  int k = ota::loadFwKeys(FW_SIGNING_KEYS);
  const esp_partition_t* run = esp_ota_get_running_partition();
  ota::BootAction a = ota::onBoot(run ? run->address : 0);
  if (!ota::idMatches(DEVICE_ID, a == ota::BOOT_TRIAL)) {
    Serial.printf("[ota] new image was built for another DEVICE_ID (%s): rejecting it\n", DEVICE_ID);
    a = ota::forceRollback();
  }
  if (a == ota::BOOT_ROLLBACK) {
    const esp_partition_t* prev = esp_ota_get_next_update_partition(nullptr);   // the other slot
    Serial.println("[ota] new image rejected or never became healthy: rolling back");
    if (prev && esp_ota_set_boot_partition(prev) == ESP_OK) { delay(200); ESP.restart(); }
    Serial.println("[ota] rollback FAILED: staying on this image");
  }
  st = ota::load();
  Serial.printf("[ota] %d pinned firmware key(s); installed release %lu%s; slot %s\n", k,
                (unsigned long)st.ver, a == ota::BOOT_TRIAL ? " (NEW image on trial)" : "",
                run ? run->label : "?");
  if (k == 0) Serial.println("[ota] no FW_SIGNING_KEYS: updates disabled (run gen_fw_keys.sh)");
  nextPollMs = millis() + 30000UL;
}

// A signed bridge ack arrived: the running image works.
static void markHealthy() {
  if (!st.pend) return;
  if (ota::onHealthy()) {
    esp_ota_mark_app_valid_cancel_rollback();
    st = ota::load();
    report("confirmed", st.ver, nullptr);
  }
}

static void consider(const char* raw, size_t n) {
  ota::Manifest m;
  const char* r = ota::parseVerify(raw, n, m);
  if (!r) r = ota::decide(m, DEVICE_ID, st.ver, st.bad);
  if (!r && st.pend) r = "trial_in_progress";
  if (r) {
    if (strcmp(r, lastReason) != 0 && strcmp(r, "not_newer") != 0) report("rejected", m.version, r);
    strncpy(lastReason, r, sizeof(lastReason) - 1);
    return;
  }
  lastReason[0] = 0;
  cand = m;
  candReady = true;
}

// From onMessage(): true if the message was the release announce.
static bool onMqtt(const char* topic, const char* buf, size_t len) {
  if (strcmp(topic, OTA_TOPIC) != 0) return false;
  if (ota::nFwKeys) consider(buf, len);
  return true;
}

// Minimal HTTP/1.0 GET. Returns the body length announced by the server, or -1.
static long httpOpen(WiFiClient& c, const char* host, const char* path) {
  if (!c.connect(host, OTA_PORT, 3000)) return -1;
  c.setTimeout(OTA_HTTP_TIMEOUT_MS / 1000);
  c.printf("GET %s HTTP/1.0\r\nHost: %s\r\n\r\n", path, host);
  String line = c.readStringUntil('\n');
  if (line.indexOf(" 200 ") < 0) return -1;
  long len = -1;
  while (true) {
    line = c.readStringUntil('\n');
    if (line.length() == 0) return -1;            // timeout
    if (line == "\r") break;
    String low = line; low.toLowerCase();
    if (low.startsWith("content-length:")) len = low.substring(15).toInt();
  }
  return len;
}

static void poll(const char* host) {
  WiFiClient c;
  long len = httpOpen(c, host, "/fw/manifest.json");
  if (len <= 0 || len > 900) { c.stop(); return; }
  char buf[901];
  size_t got = c.readBytes(buf, len);
  c.stop();
  if ((long)got == len) consider(buf, got);
}

static bool install(const char* host) {
  const ota::Manifest m = cand;
  const esp_partition_t* slot = esp_ota_get_next_update_partition(nullptr);
  if (!slot || m.size > slot->size) { report("failed", m.version, "no_slot"); return false; }
  WiFiClient c;
  long len = httpOpen(c, host, m.path);
  if (len != (long)m.size) { c.stop(); report("failed", m.version, len < 0 ? "http" : "size_mismatch"); return false; }
  if (!Update.begin(m.size, U_FLASH)) { c.stop(); report("failed", m.version, "update_begin"); return false; }
  report("downloading", m.version, nullptr);
  ota::Hasher h; h.begin();
  const size_t BUFSZ = 2048;                    // heap, only during a download (DRAM is tight)
  struct Buf { uint8_t* p; ~Buf() { free(p); } } hb{(uint8_t*)malloc(BUFSZ)};
  if (!hb.p) { c.stop(); Update.abort(); report("failed", m.version, "no_memory"); return false; }
  uint8_t* buf = hb.p;
  uint32_t done = 0;
  unsigned long lastData = millis();
  while (done < m.size) {
    int avail = c.available();
    if (avail <= 0) {
      if (!c.connected() || millis() - lastData > OTA_HTTP_TIMEOUT_MS) break;
      delay(5);
      continue;
    }
    size_t want = m.size - done;
    if (want > BUFSZ) want = BUFSZ;
    int r = c.read(buf, want);
    if (r <= 0) continue;
    h.update(buf, r);
    if (Update.write(buf, r) != (size_t)r) break;
    done += r;
    lastData = millis();
    if (mq) mq->loop();                           // keep the MQTT session alive
  }
  c.stop();
  if (done != m.size || !h.matches(m)) {
    Update.abort();
    report("failed", m.version, done != m.size ? "truncated" : "sha256_mismatch");
    return false;
  }
  if (!Update.end(true)) { report("failed", m.version, "image_invalid"); return false; }   // also sets the boot slot
  ota::onInstalled(m.version, slot->address);
  report("installed", m.version, "rebooting");
  return true;
}

// From loop(), while connected. host = the broker currently in use.
static void service(const char* host) {
  if (!ota::nFwKeys) return;
  unsigned long now = millis();
  if (!candReady && (long)(now - nextPollMs) >= 0) {
    nextPollMs = now + OTA_CHECK_MS;
    poll(host);
  }
  if (!candReady || (long)(now - retryAfterMs) < 0) return;
  if (install(host)) {
    if (mq) { mq->loop(); mq->disconnect(); }
    delay(300);
    ESP.restart();
  }
  static int attempts = 0;
  if (++attempts >= 3) { candReady = false; attempts = 0; }   // the next announce/poll offers it again
  retryAfterMs = millis() + OTA_RETRY_MS;
}
}  // namespace otadev

#else   // OTA disabled, or the host check (which tests ota_core.h on its own)
namespace otadev {
static inline void begin(PubSubClient&) {}
static inline void markHealthy() {}
static inline bool onMqtt(const char* topic, const char*, size_t) { return strcmp(topic, OTA_TOPIC) == 0; }
static inline void service(const char*) {}
}
#endif
