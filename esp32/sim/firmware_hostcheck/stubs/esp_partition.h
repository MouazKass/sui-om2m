#pragma once
// Host model of the ESP32 "spiffs" data partition as real NOR flash, for
// flash_buffer.h. Unlike a plain byte array it enforces the two rules the
// hardware has: erase only whole 4 KB sectors (to 0xFF), and a write can only
// clear bits. A write that would need a 0 -> 1 bit is counted in
// g_flash_violations (real flash would silently store old & new: corruption).
// The contents survive "reboots" inside one host run, like the NVS stub.
#include <cstdint>
#include <cstring>
#include <vector>

typedef int esp_err_t;
#define ESP_OK 0
#define ESP_FAIL -1
typedef enum { ESP_PARTITION_TYPE_APP = 0, ESP_PARTITION_TYPE_DATA = 1 } esp_partition_type_t;
typedef enum { ESP_PARTITION_SUBTYPE_DATA_SPIFFS = 0x82 } esp_partition_subtype_t;
typedef struct { uint32_t address, size; } esp_partition_t;

inline std::vector<uint8_t>& g_flash() {
  static std::vector<uint8_t> f(64 * 4096, 0xFF);   // 64 sectors unless a test resizes it
  return f;
}
inline bool& g_part_missing() { static bool m = false; return m; }
inline uint32_t& g_flash_violations() { static uint32_t v = 0; return v; }
inline uint32_t& g_flash_erases() { static uint32_t e = 0; return e; }

inline const esp_partition_t* esp_partition_find_first(esp_partition_type_t, esp_partition_subtype_t, const char*) {
  static esp_partition_t p;
  if (g_part_missing()) return nullptr;
  p.address = 0x290000;
  p.size = (uint32_t)g_flash().size();
  return &p;
}
inline esp_err_t esp_partition_read(const esp_partition_t* p, size_t off, void* dst, size_t n) {
  if (!p || off + n > g_flash().size()) return ESP_FAIL;
  memcpy(dst, g_flash().data() + off, n);
  return ESP_OK;
}
inline esp_err_t esp_partition_write(const esp_partition_t* p, size_t off, const void* src, size_t n) {
  if (!p || off + n > g_flash().size()) return ESP_FAIL;
  const uint8_t* s = (const uint8_t*)src;
  for (size_t i = 0; i < n; i++) {
    uint8_t& b = g_flash()[off + i];
    if ((b & s[i]) != s[i]) g_flash_violations()++;
    b &= s[i];
  }
  return ESP_OK;
}
inline esp_err_t esp_partition_erase_range(const esp_partition_t* p, size_t off, size_t n) {
  if (!p || off % 4096 || n % 4096 || off + n > g_flash().size()) return ESP_FAIL;
  memset(g_flash().data() + off, 0xFF, n);
  g_flash_erases()++;
  return ESP_OK;
}
