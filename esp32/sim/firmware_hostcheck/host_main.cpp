// Compiles the REAL firmware source against host stubs and runs a scripted,
// virtual-time scenario against a simulated 5-node cluster:
//
//    0 s  all brokers up            -> connects to home (rpi2)
//    5 s  retained membership lists a new node rpi6 (+ one outside the subnet)
//   20 s  home broker dies          -> fails over within 10 s, buffers + resends
//   40 s  home broker back          -> returns only after HOME_STABLE_MS (hysteresis)
//   58 s  home broker up but its BRIDGE stops acking (until 80 s)
//                                   -> fails over after NO_ACK_FAILOVER_MS, nothing lost
//  58-80 s an attacker on the home broker publishes FORGED acks for every
//          reading (unsigned, rogue key, wrong device, tampered)
//                                   -> all ignored: the failover still happens
//                                      and no reading is dropped unstored
//  100 s  power cycle               -> epoch +1 from NVS
//
// The simulated bridges sign their acks with the RFC 8032 test-vector-1 key,
// pinned below as ACK_TRUSTED_KEYS (exactly as gen_ack_keys.sh pins real ones).
//
// Exit code 0 only if every check passes. stdout keeps the PUB lines that
// sim/run_e2e.py scenario 5 replays into a real broker.
//
//   g++ -std=c++17 -Wall -I stubs -o /tmp/fw_host host_main.cpp && /tmp/fw_host > /tmp/fw_pub.txt
#define PUBLISH_INTERVAL_MS 1000UL
#define HOME_PROBE_MS 2000UL
#define HOME_STABLE_MS 10000UL
#define ACK_WAIT_MS 1500UL
#define NO_ACK_FAILOVER_MS 5000UL
#define ACK_TRUSTED_KEYS "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
#include <map>
#include <set>
#include <string>
#include <vector>
#include "Arduino.h"
#include "WiFi.h"
#include "Preferences.h"
#include "PubSubClient.h"
unsigned long g_virtual_ms = 0;
HostSerial Serial; HostESP ESP; HostWiFi WiFi;
std::set<std::string> g_down;
std::map<std::string, uint32_t> g_nvs;
std::map<std::string, std::string> g_nvs_bytes;
std::string g_brokers_retained;
std::vector<HostBridgeEvent> g_events;
#include "../../firmware/esp32_sensor_node/esp32_sensor_node.ino"

// ---- the bridges' ack signer (and an attacker's) ------------------------------
static unsigned char bridgePk[32], bridgeSk[64], roguePk[32], rogueSk[64];
static void initSigners() {
  unsigned char seed[32];
  devkey::fromHex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", 32, seed);
  crypto_sign_seed_keypair(bridgePk, bridgeSk, seed);
  memset(seed, 0x42, sizeof(seed));
  crypto_sign_seed_keypair(roguePk, rogueSk, seed);
}
// {"id":..,"seq":..,"node":..,"epoch":..,"ts":0,"apk":..} + sig, like esp_identity.sign_ack
static std::string signedAck(const char* id, unsigned long epoch, long seq,
                             const unsigned char* pk, const unsigned char* sk) {
  char apk[65], body[400], sigHex[129];
  devkey::toHex(pk, 32, apk);
  snprintf(body, sizeof(body), "{\"id\":\"%s\",\"seq\":%ld,\"node\":\"host\",\"epoch\":%lu,\"ts\":0,\"apk\":\"%s\"}",
           id, seq, epoch, apk);
  std::string m = std::string(devkey::ACK_DOMAIN, sizeof(devkey::ACK_DOMAIN)) + body;
  unsigned char sig[64];
  crypto_sign_detached(sig, nullptr, (const unsigned char*)m.data(), m.size(), sk);
  devkey::toHex(sig, 64, sigHex);
  std::string b(body);
  return b.substr(0, b.size() - 1) + ",\"sig\":\"" + sigHex + "\"}";
}

static int failures = 0;
static void check(const char* name, bool ok, const std::string& detail = "") {
  fprintf(stderr, "  [%s] %s  %s\n", ok ? "PASS" : "FAIL", name, detail.c_str());
  if (!ok) failures++;
}
static long field(const std::string& p, const char* key) {
  size_t i = p.find(key);
  return i == std::string::npos ? -1 : strtol(p.c_str() + i + strlen(key), nullptr, 10);
}

int main() {
  const std::string HOME = "10.25.96.201:1883";
  std::set<long> stored;            // the "cluster store": what any bridge stored
  long dupDeliveries = 0;
  size_t seen = 0;
  unsigned long failoverAt = 0, homeAgainAt = 0, silentFailoverAt = 0;
  bool clearedRetained = false;

  initSigners();
  setup();
  uint32_t epoch1 = epoch;
  long forgedSent = 0;
  uint32_t rejectedBefore = 0;
  while (g_virtual_ms < 100000) {
    bool silent = g_virtual_ms >= 58000 && g_virtual_ms < 80000;
    if (g_virtual_ms >= 5000 && g_brokers_retained.empty())
      g_brokers_retained = "v1;1700000000;rpi1=10.25.96.200:1883:1,rpi2=10.25.96.201:1883:1,"
                           "rpi3=10.25.96.203:1883:1,rpi4=10.25.96.204:1883:1,rpi5=10.25.96.205:1883:1,"
                           "rpi6=10.25.96.206:1883:1,evil=203.0.113.9:1883:1";
    if (g_virtual_ms >= 20000 && g_virtual_ms < 40000) g_down.insert(HOME);
    if (g_virtual_ms >= 40000) g_down.erase(HOME);
    loop();
    g_virtual_ms += 100;
    // The Pi side: store telemetry once, ack the highest stored seq on the
    // broker it arrived on (only if the sensor is still attached there).
    for (; seen < g_events.size(); seen++) {
      const HostBridgeEvent& e = g_events[seen];
      bool tele = e.topic.find("/telemetry") != std::string::npos;
      bool stat = e.topic.find("/status") != std::string::npos;
      if (stat && e.retained && e.payload.empty() && e.broker != HOME) clearedRetained = true;
      if (tele) {
        long s = field(e.payload, "\"seq\":");
        if (!stored.insert(s).second) dupDeliveries++;
        if (e.broker != HOME && g_virtual_ms >= 20000 && !failoverAt) failoverAt = e.t;
        if (e.broker == HOME && failoverAt && !homeAgainAt) homeAgainAt = e.t;
        if (e.broker != HOME && e.t >= 58000 && !silentFailoverAt) silentFailoverAt = e.t;
      }
      // per-reading ack, exactly like the bridge (stored or duplicate): signed
      if (tele && !(silent && e.broker == HOME) && mqtt.connected() &&
          hp(mqtt.host.c_str(), mqtt.port) == e.broker) {
        std::string ack = signedAck(DEVICE_ID, epoch, field(e.payload, "\"seq\":"), bridgePk, bridgeSk);
        mqtt.deliver(topicAck, ack.c_str());
      }
      // the attacker on the silent home broker: forged acks for this very reading
      if (tele && silent && e.broker == HOME && mqtt.connected() &&
          hp(mqtt.host.c_str(), mqtt.port) == e.broker) {
        long sq = field(e.payload, "\"seq\":");
        if (!forgedSent) rejectedBefore = devkey::acksRejected;
        char plain[96];
        snprintf(plain, sizeof(plain), "{\"id\":\"%s\",\"epoch\":%lu,\"seq\":%ld}", DEVICE_ID,
                 (unsigned long)epoch, sq);
        std::string rogue = signedAck(DEVICE_ID, epoch, sq, roguePk, rogueSk);
        std::string other = signedAck("esp32-other-99", epoch, sq, bridgePk, bridgeSk);
        std::string tampered = signedAck(DEVICE_ID, epoch, sq + 1000, bridgePk, bridgeSk);
        size_t at = tampered.find("\"seq\":");
        tampered.replace(at, tampered.find(',', at) - at, "\"seq\":" + std::to_string(sq));
        for (const std::string& f : {std::string(plain), rogue, other, tampered}) {
          mqtt.deliver(topicAck, f.c_str());
          forgedSent++;
        }
      }
    }
  }

  fprintf(stderr, "\nhost-check results\n");
  check("connected to the home broker first", !g_events.empty() && g_events[0].broker == HOME,
        g_events.empty() ? "no events" : g_events[0].broker);
  check("Last Will carries the session id", mqtt.willMsg.find("\"session\":\"") != std::string::npos,
        mqtt.willMsg);
  check("learned rpi6 from the retained membership topic", sel.find("rpi6") >= 0,
        std::to_string(sel.n) + " brokers known");
  check("ignored a learned host outside CLUSTER_ALLOW_PREFIX", sel.find("evil") < 0);
  check("failed over to another broker within 10 s", failoverAt && failoverAt - 20000 <= 10000,
        "after " + std::to_string(failoverAt ? failoverAt - 20000 : 0) + " ms");
  check("returned home only after the stability window",
        homeAgainAt >= 40000 + HOME_STABLE_MS && homeAgainAt <= 40000 + HOME_STABLE_MS + HOME_PROBE_MS + 3000,
        "home again at " + std::to_string(homeAgainAt) + " ms (home up at 40000)");
  check("cleared its retained presence on the broker it left", clearedRetained);
  check("failed over when the home bridge stopped acknowledging",
        silentFailoverAt && silentFailoverAt - 58000 <= NO_ACK_FAILOVER_MS + PUBLISH_INTERVAL_MS + 3000,
        "after " + std::to_string(silentFailoverAt ? silentFailoverAt - 58000 : 0) + " ms");
  bool complete = true;
  for (long s = 0; s + 1 < (long)seqNo; s++) if (!stored.count(s)) { complete = false; break; }
  check("no reading lost across failover and return (resend buffer)", complete,
        std::to_string(stored.size()) + " distinct of " + std::to_string(seqNo) + " taken, " +
        std::to_string(dupDeliveries) + " duplicate deliveries for the bridge to drop");

  bool allSigned = true;
  for (const HostBridgeEvent& e : g_events) {
    bool tele = e.topic.find("/telemetry") != std::string::npos;
    if (tele && (e.payload.find("\"pk\":\"") == std::string::npos ||
                 e.payload.find(",\"sig\":\"") == std::string::npos)) { allSigned = false; break; }
  }
  check("every telemetry message carries pk and sig", allSigned);
  check("every forged ack was ignored (unsigned, rogue key, other device, tampered)",
        forgedSent > 0 && (long)(devkey::acksRejected - rejectedBefore) == forgedSent,
        std::to_string(forgedSent) + " forged, " + std::to_string(devkey::acksRejected - rejectedBefore) +
        " ignored");
  check("genuine signed acks were accepted (the board pinned the bridge key)", devkey::nAckKeys == 1,
        std::to_string(devkey::nAckKeys) + " pinned");
  check("Last Will is signed too", mqtt.willMsg.find(",\"sig\":\"") != std::string::npos, mqtt.willMsg);
  std::string pk1 = devkey::pkHex;
  setup();                                    // power cycle
  check("power cycle increments the NVS epoch", epoch == epoch1 + 1,
        std::to_string(epoch1) + " -> " + std::to_string(epoch));
  check("device key survives the power cycle (kept in NVS)", pk1 == devkey::pkHex, pk1);
  fprintf(stderr, "[id] host-check device address %s\n", devkey::addrHex);
  fprintf(stderr, "%s\n", failures ? "FAILED" : "all host checks passed");
  return failures ? 1 : 0;
}
