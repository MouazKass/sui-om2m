#pragma once
#include <map>
#include <string>
#include "Arduino.h"
// In-memory NVS. g_nvs survives "reboots" inside one host run (host_main can
// call setup() again to model a power cycle).
extern std::map<std::string, uint32_t> g_nvs;
struct Preferences {
  std::string ns;
  bool begin(const char* n, bool) { ns = n; return true; }
  uint32_t getUInt(const char* k, uint32_t d) { auto it = g_nvs.find(ns + "/" + k); return it == g_nvs.end() ? d : it->second; }
  size_t putUInt(const char* k, uint32_t v) { g_nvs[ns + "/" + k] = v; return 4; }
  void end() {}
};
