#pragma once
#include <set>
#include <string>
#include "Arduino.h"
#define WL_CONNECTED 3
#define WIFI_STA 1
struct IPAddress { std::string toString() const { return "10.25.96.150"; } };
struct HostWiFi {
  int st = 3;
  void mode(int) {}
  void begin(const char*, const char*) {}
  int status() { return st; }
  void reconnect() {}
  IPAddress localIP() { return IPAddress(); }
  int RSSI() { return -58; }
};
extern HostWiFi WiFi;
// The simulated network: "host:port" strings that are down.
extern std::set<std::string> g_down;
inline std::string hp(const char* h, uint16_t p) { return std::string(h) + ":" + std::to_string(p); }
struct WiFiClient {
  bool up = false; std::string target;
  int connect(const char* h, uint16_t p, int32_t timeout_ms) {
    target = hp(h, p);
    if (g_down.count(target)) { g_virtual_ms += (unsigned long)timeout_ms; up = false; return 0; }
    up = true; return 1;
  }
  bool connected() { return up && !g_down.count(target); }
  void stop() { up = false; }
};
