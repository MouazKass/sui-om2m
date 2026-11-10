#pragma once
#include <functional>
#include <string>
#include <vector>
#include "Arduino.h"
#include "WiFi.h"
// Host stand-in for PubSubClient. It also plays the Pi side: a bridge that
// stores telemetry (per broker) and acknowledges it on sensors/<id>/ack, and
// a retained om2m/cluster/brokers message (g_brokers_retained).
// Every publish is printed as: PUB<TAB>topic<TAB>retained<TAB>payload  (stdout)
extern std::string g_brokers_retained;
struct HostBridgeEvent { unsigned long t; std::string broker; std::string topic; std::string payload; bool retained; };
extern std::vector<HostBridgeEvent> g_events;
struct PubSubClient {
  WiFiClient* net; std::string host; uint16_t port = 0; bool conn = false; int st = -1;
  std::string willTopic, willMsg;
  std::vector<std::pair<std::string, std::string>> inbox;
  void (*cb)(char*, uint8_t*, unsigned int) = nullptr;
  std::vector<std::string> subs;
  PubSubClient(WiFiClient& c) : net(&c) {}
  void setServer(const char* h, uint16_t p) { host = h; port = p; }
  bool setBufferSize(int) { return true; }
  void setKeepAlive(int) {}
  void setSocketTimeout(int) {}
  void setCallback(void (*f)(char*, uint8_t*, unsigned int)) { cb = f; }
  bool connect(const char* id, const char* u, const char* p, const char* wt, uint8_t wq, bool wr, const char* wm) {
    if (g_down.count(hp(host.c_str(), port))) { conn = false; st = -2; return false; }
    conn = true; st = 0; willTopic = wt; willMsg = wm; subs.clear();
    printf("WILL\t%s\t%d\t%s\n", wt, (int)wr, wm);
    return true;
  }
  bool connected() {
    if (conn && g_down.count(hp(host.c_str(), port))) { conn = false; st = -3; }
    return conn;
  }
  int state() { return st; }
  bool subscribe(const char* t, int) {
    subs.push_back(t);
    if (std::string(t) == "om2m/cluster/brokers" && !g_brokers_retained.empty())
      inbox.push_back({t, g_brokers_retained});
    return true;
  }
  void deliver(const std::string& t, const std::string& p) { inbox.push_back({t, p}); }
  void loop() {
    auto q = inbox; inbox.clear();
    for (auto& m : q) if (cb) cb((char*)m.first.c_str(), (uint8_t*)m.second.data(), (unsigned)m.second.size());
  }
  void disconnect() { conn = false; st = -1; }
  bool publish(const char* t, const char* p, bool r) { return publish(t, (const uint8_t*)p, (unsigned)strlen(p), r); }
  bool publish(const char* t, const uint8_t* p, unsigned len, bool r) {
    if (!connected()) return false;
    std::string payload((const char*)p, len);
    printf("PUB\t%s\t%d\t%s\n", t, (int)r, payload.c_str());
    g_events.push_back({g_virtual_ms, hp(host.c_str(), port), t, payload, r});
    return true;
  }
};
