// ============================================================================
//  ota_core.h - signed firmware updates: the decision logic (fw 2.4)
//
//  Pure logic, no radio and no flash: compiled into the firmware (via ota.h) and
//  into the host check (sim/firmware_hostcheck/ota_test.cpp). It mirrors
//  pi/ota_manifest.py byte for byte; see that file for the manifest format.
//
//  A release is accepted only if the manifest is signed by a PINNED firmware key
//  (fw_keys.h, from deploy/v9/fw_keys/ via firmware/gen_fw_keys.sh) under the
//  domain tag "om2m-esp32-fw-v1\0", is for this device (or "all"), is newer than
//  the installed version and than any version that failed here, fits one OTA
//  slot, and the image then matches its size and SHA-256.
//
//  Rollback state (NVS namespace "sui-ota"):
//    ver   installed release version (0 = the USB-flashed build)
//    pend  version written to the other slot and booted, not yet proven healthy
//    tries boots of `pend` so far       bad  highest version that rolled back
//    pslot flash address of the slot `pend` was written to
//  A new image must reach "healthy" (connected + a SIGNED bridge ack) within
//  OTA_MAX_TRIES boots, otherwise the board switches back to the old slot.
// ============================================================================
#pragma once
#include <Preferences.h>
#include <sodium.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if !defined(FW_SIGNING_KEYS) && defined(__has_include)
#if __has_include("fw_keys.h")
#include "fw_keys.h"
#endif
#endif
#ifndef FW_SIGNING_KEYS
#define FW_SIGNING_KEYS ""             // "hex64,..." (at most 4); none = no update accepted
#endif
#ifndef OTA_SLOT_SIZE
#define OTA_SLOT_SIZE 0x140000UL       // "default" partition table: app0/app1 = 1.25 MB each
#endif
#ifndef OTA_MAX_TRIES
#define OTA_MAX_TRIES 3
#endif

namespace ota {

static const char FW_DOMAIN[] = "om2m-esp32-fw-v1";     // + NUL = 17 bytes
static const char* NVS_NS = "sui-ota";
static unsigned char fwKeys[4][crypto_sign_PUBLICKEYBYTES];
static int nFwKeys = 0;

struct Manifest {
  uint32_t version = 0, size = 0;
  char sha256[65] = {0};
  char path[80] = {0};
  char target[48] = {0};
};

static inline int hexv(char c) {
  return (c >= '0' && c <= '9') ? c - '0' : (c >= 'a' && c <= 'f') ? c - 'a' + 10
       : (c >= 'A' && c <= 'F') ? c - 'A' + 10 : -1;
}
static inline bool unhex(const char* in, size_t n, unsigned char* out) {
  for (size_t i = 0; i < n; i++) {
    int a = hexv(in[2 * i]), b = hexv(in[2 * i + 1]);
    if (a < 0 || b < 0) return false;
    out[i] = (unsigned char)(a * 16 + b);
  }
  return true;
}

static inline int loadFwKeys(const char* csv) {
  nFwKeys = 0;
  const char* p = csv;
  while (*p && nFwKeys < 4) {
    while (*p == ',' || *p == ' ') p++;
    if (strlen(p) < 64) break;
    if (unhex(p, 32, fwKeys[nFwKeys])) nFwKeys++;
    p += 64;
  }
  return nFwKeys;
}

// Exactly one occurrence of "key": in the body (no duplicate-key confusion).
static inline const char* field(const char* body, const char* key) {
  char pat[24];
  snprintf(pat, sizeof(pat), "\"%s\":", key);
  const char* a = strstr(body, pat);
  if (!a || strstr(a + 1, pat)) return nullptr;
  return a + strlen(pat);
}
static inline bool getUInt(const char* body, const char* key, uint32_t& out) {
  const char* v = field(body, key);
  if (!v || *v < '0' || *v > '9') return false;
  char* end;
  unsigned long x = strtoul(v, &end, 10);
  if (end - v > 10 || (*end != ',' && *end != '}')) return false;
  out = (uint32_t)x;
  return true;
}
static inline bool getStr(const char* body, const char* key, char* out, size_t cap) {
  const char* v = field(body, key);
  if (!v || *v != '"') return false;
  v++;
  const char* e = strchr(v, '"');
  if (!e || (size_t)(e - v) >= cap) return false;
  for (const char* c = v; c < e; c++) if (*c == '\\') return false;   // no escapes in a manifest
  memcpy(out, v, e - v);
  out[e - v] = 0;
  return e[1] == ',' || e[1] == '}';
}

// raw: the manifest as received. On success fills m and returns nullptr; else a reason.
static inline const char* parseVerify(const char* raw, size_t n, Manifest& m) {
  static const char SIG[] = ",\"sig\":\"";
  const size_t sl = sizeof(SIG) - 1;
  while (n && (raw[n - 1] == '\n' || raw[n - 1] == '\r' || raw[n - 1] == ' ')) n--;
  if (n < sl + 130 + 2 || n > 900) return "malformed";
  size_t i = n - (sl + 128 + 2);
  if (memcmp(raw + i, SIG, sl) != 0 || raw[n - 2] != '"' || raw[n - 1] != '}') return "unsigned";
  unsigned char sig[crypto_sign_BYTES];
  if (!unhex(raw + i + sl, crypto_sign_BYTES, sig)) return "bad_sig_format";
  // One heap buffer, only while a manifest is checked (DRAM is tight on the
  // ESP32): msg = FW_DOMAIN \0 || body, and body is parsed in place.
  struct Buf { unsigned char* p; ~Buf() { free(p); } } mb{(unsigned char*)malloc(sizeof(FW_DOMAIN) + i + 2)};
  if (!mb.p) return "no_memory";
  unsigned char* msg = mb.p;
  char* body = (char*)msg + sizeof(FW_DOMAIN);
  memcpy(msg, FW_DOMAIN, sizeof(FW_DOMAIN));             // includes the NUL
  memcpy(body, raw, i);
  body[i] = '}';
  body[i + 1] = 0;
  if (memchr(body, 0, i)) return "malformed";
  char fpk[65], kind[16];
  if (!getStr(body, "fpk", fpk, sizeof(fpk)) || strlen(fpk) != 64) return "bad_fields";
  unsigned char pk[crypto_sign_PUBLICKEYBYTES];
  if (!unhex(fpk, 32, pk)) return "bad_fields";
  bool pinned = false;
  for (int k = 0; k < nFwKeys && !pinned; k++) pinned = memcmp(pk, fwKeys[k], sizeof(pk)) == 0;
  if (!pinned) return "untrusted_key";
  if (crypto_sign_verify_detached(sig, msg, sizeof(FW_DOMAIN) + i + 1, pk) != 0) return "bad_signature";
  uint32_t ts;
  if (!getStr(body, "kind", kind, sizeof(kind)) || !getUInt(body, "version", m.version) ||
      !getStr(body, "target", m.target, sizeof(m.target)) || !getUInt(body, "size", m.size) ||
      !getStr(body, "sha256", m.sha256, sizeof(m.sha256)) ||
      !getStr(body, "path", m.path, sizeof(m.path)) || !getUInt(body, "ts", ts))
    return "bad_fields";
  if (strcmp(kind, "om2m-fw") != 0) return "wrong_kind";
  return nullptr;
}

static inline bool pathOk(const char* p) {
  size_t n = strlen(p);
  if (n < 9 || n > 72 || strncmp(p, "/fw/", 4) != 0 || strcmp(p + n - 4, ".bin") != 0) return false;
  for (size_t i = 4; i < n - 4; i++) {
    char c = p[i];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
          c == '.' || c == '_' || c == '-')) return false;
  }
  return true;
}

// nullptr = download it; else the reason not to (same order as ota_manifest.decide).
static inline const char* decide(const Manifest& m, const char* device, uint32_t installed, uint32_t bad,
                          uint32_t slot = OTA_SLOT_SIZE) {
  if (strcmp(m.target, "all") != 0 && strcmp(m.target, device) != 0) return "not_for_this_device";
  if (m.version == 0) return "bad_version";
  if (m.version <= installed) return "not_newer";
  if (m.version <= bad) return "failed_before";
  if (m.size == 0 || m.size > slot) return "bad_size";
  if (strlen(m.sha256) != 64) return "bad_sha256";
  for (int k = 0; k < 64; k++) if (!((m.sha256[k] >= '0' && m.sha256[k] <= '9') ||
                                     (m.sha256[k] >= 'a' && m.sha256[k] <= 'f'))) return "bad_sha256";
  if (!pathOk(m.path)) return "bad_path";
  return nullptr;
}

// Streaming SHA-256 over the downloaded image.
struct Hasher {
  crypto_hash_sha256_state st;
  uint32_t n = 0;
  void begin() { crypto_hash_sha256_init(&st); n = 0; }
  void update(const uint8_t* d, size_t len) { crypto_hash_sha256_update(&st, d, len); n += len; }
  bool matches(const Manifest& m) {
    unsigned char h[32];
    crypto_hash_sha256_final(&st, h);
    static const char* x = "0123456789abcdef";
    char hex[65];
    for (int i = 0; i < 32; i++) { hex[2 * i] = x[h[i] >> 4]; hex[2 * i + 1] = x[h[i] & 15]; }
    hex[64] = 0;
    return n == m.size && strcmp(hex, m.sha256) == 0;
  }
};

// ---- rollback state ----------------------------------------------------------
struct State { uint32_t ver = 0, pend = 0, tries = 0, bad = 0, pslot = 0; };
static inline State load() {
  State s; Preferences p; p.begin(NVS_NS, true);
  s.ver = p.getUInt("ver", 0); s.pend = p.getUInt("pend", 0);
  s.tries = p.getUInt("tries", 0); s.bad = p.getUInt("bad", 0); s.pslot = p.getUInt("pslot", 0);
  p.end(); return s;
}
static inline void save(const State& s) {
  Preferences p; p.begin(NVS_NS, false);
  p.putUInt("ver", s.ver); p.putUInt("pend", s.pend); p.putUInt("tries", s.tries); p.putUInt("bad", s.bad);
  p.putUInt("pslot", s.pslot);
  p.end();
}

enum BootAction { BOOT_NORMAL, BOOT_TRIAL, BOOT_ROLLBACK };
// Called once per boot, before anything else can crash. runningSlot = flash
// address of the partition this image runs from.
static inline BootAction onBoot(uint32_t runningSlot) {
  State s = load();
  if (!s.pend) return BOOT_NORMAL;
  if (runningSlot != s.pslot) {               // the old image is running: the bootloader
    if (s.pend > s.bad) s.bad = s.pend;       // already rolled back (or the write never
    s.pend = 0; s.tries = 0; save(s);         // took). Never "roll back" onto the bad slot.
    return BOOT_NORMAL;
  }
  s.tries++;
  if (s.tries > OTA_MAX_TRIES) {              // never became healthy: give up on it
    if (s.pend > s.bad) s.bad = s.pend;
    s.pend = 0; s.tries = 0;
    save(s);
    return BOOT_ROLLBACK;
  }
  save(s);
  return BOOT_TRIAL;
}
// DEVICE_ID is compiled into the image (config_local.h), so an image built for
// another board would rename this one and break its on-chain identity. The ID
// the board was first flashed with is kept in NVS: a USB flash may change it
// (operator intent), an OTA image on trial may not. false = reject the image.
static inline bool idMatches(const char* compiled, bool onTrial) {
  Preferences p; p.begin(NVS_NS, false);
  char stored[49] = {0};
  size_t n = p.getBytesLength("devid");
  if (n > 0 && n < sizeof(stored)) p.getBytes("devid", stored, n);
  bool ok = true;
  if (onTrial && n > 0) ok = strcmp(stored, compiled) == 0;
  else if (n == 0 || strcmp(stored, compiled) != 0) p.putBytes("devid", compiled, strlen(compiled));
  p.end();
  return ok;
}
// The running trial image must go (wrong device ID): mark it failed, roll back.
static inline BootAction forceRollback() {
  State s = load();
  if (s.pend > s.bad) s.bad = s.pend;
  s.pend = 0; s.tries = 0; save(s);
  return BOOT_ROLLBACK;
}

// The new image is written and will boot next: start its trial.
static inline void onInstalled(uint32_t version, uint32_t slot) {
  State s = load(); s.pend = version; s.tries = 0; s.pslot = slot; save(s);
}
// Connected and a signed bridge ack arrived: the running image works. true if it
// just finished a trial (the caller then also cancels the bootloader rollback).
static inline bool onHealthy() {
  State s = load();
  if (!s.pend) return false;
  s.ver = s.pend; s.pend = 0; s.tries = 0; save(s);
  return true;
}

}  // namespace ota
