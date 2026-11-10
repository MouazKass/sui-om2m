#pragma once
#include <map>
#include <string>
#include "Arduino.h"
// In-memory NVS. g_nvs survives "reboots" inside one host run (host_main can
// call setup() again to model a power cycle).
extern std::map<std::string, uint32_t> g_nvs;
extern std::map<std::string, std::string> g_nvs_bytes;
struct Preferences {
  std::string ns;
  bool begin(const char* n, bool) { ns = n; return true; }
  uint32_t getUInt(const char* k, uint32_t d) { auto it = g_nvs.find(ns + "/" + k); return it == g_nvs.end() ? d : it->second; }
  size_t putUInt(const char* k, uint32_t v) { g_nvs[ns + "/" + k] = v; return 4; }
  size_t getBytesLength(const char* k) { auto it = g_nvs_bytes.find(ns + "/" + k); return it == g_nvs_bytes.end() ? 0 : it->second.size(); }
  size_t getBytes(const char* k, void* buf, size_t max) {
    auto it = g_nvs_bytes.find(ns + "/" + k);
    if (it == g_nvs_bytes.end()) return 0;
    size_t n = it->second.size() < max ? it->second.size() : max;
    memcpy(buf, it->second.data(), n); return n;
  }
  size_t putBytes(const char* k, const void* v, size_t n) { g_nvs_bytes[ns + "/" + k] = std::string((const char*)v, n); return n; }
  void end() {}
};
