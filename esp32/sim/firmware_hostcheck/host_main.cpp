// Compiles the REAL firmware source against host stubs and runs a scripted,
// virtual-time scenario against a simulated 5-node cluster:
//
//    0 s  all brokers up            -> connects to home (rpi2)
//    5 s  retained membership lists a new node rpi6 (+ one outside the subnet)
//   20 s  home broker dies          -> fails over within 10 s, buffers + resends
//   40 s  home broker back          -> returns only after HOME_STABLE_MS (hysteresis)
//   58 s  home broker up but its BRIDGE stops acking (until 80 s)
//                                   -> fails over after NO_ACK_FAILOVER_MS, nothing lost
//  100 s  power cycle               -> epoch +1 from NVS
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

  setup();
  uint32_t epoch1 = epoch;
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
      // per-reading ack, exactly like the bridge (stored or duplicate)
      if (tele && !(silent && e.broker == HOME) && mqtt.connected() &&
          hp(mqtt.host.c_str(), mqtt.port) == e.broker) {
        char ack[96];
        snprintf(ack, sizeof(ack), "{\"epoch\":%lu,\"seq\":%ld}", (unsigned long)epoch,
                 field(e.payload, "\"seq\":"));
        mqtt.deliver(topicAck, ack);
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
