// ============================================================================
//  device_key.h - the sensor's own Ed25519 identity (v2.1)
//
//  The key is generated ON the device on first boot (libsodium randombytes,
//  backed by the ESP32 hardware RNG with the radio on) and kept in NVS. It is
//  never printed or sent anywhere; only the PUBLIC key and its Sui address are
//  printed on the serial console, so an operator can register the device
//  on-chain by a council vote:
//
//      scripts/v9/council.sh propose rpi1 id-register <address> <DEVICE_ID> 3
//
//  (address = blake2b-256(0x00 || public key), Sui's Ed25519 address scheme;
//  role 3 = ROLE_AE). Deregistering it (id-deregister) revokes the device.
//
//  Every telemetry and status message gets "pk" and, as its LAST field, "sig":
//      sig = Ed25519(sk, "om2m-esp32-sig-v1\0" || <message without the sig field>)
//  The bridge (pi/esp_identity.py) verifies it and checks the registry.
//
//  libsodium ships with the ESP32 Arduino core (#include <sodium.h>); the host
//  check links the system libsodium. For production, enable NVS/flash
//  encryption so the seed cannot be read off a stolen board.
// ============================================================================
#pragma once
#include <Preferences.h>
#include <sodium.h>
#include <string.h>

namespace devkey {

static unsigned char pk[crypto_sign_PUBLICKEYBYTES];
static unsigned char sk[crypto_sign_SECRETKEYBYTES];
static char pkHex[2 * crypto_sign_PUBLICKEYBYTES + 1];
static char addrHex[2 + 64 + 1];
static bool ready = false;
static const char DOMAIN[] = "om2m-esp32-sig-v1";   // + its NUL terminator = 18 bytes

static void toHex(const unsigned char* in, size_t n, char* out) {
  static const char* d = "0123456789abcdef";
  for (size_t i = 0; i < n; i++) { out[2 * i] = d[in[i] >> 4]; out[2 * i + 1] = d[in[i] & 15]; }
  out[2 * n] = 0;
}

// Load the seed from NVS, or create it. Call once the radio is on (WiFi.mode).
static bool init(const char* nvsNamespace) {
  if (sodium_init() < 0) return false;
  unsigned char seed[crypto_sign_SEEDBYTES];
  Preferences p;
  p.begin(nvsNamespace, false);
  if (p.getBytesLength("sk_seed") == sizeof(seed)) {
    p.getBytes("sk_seed", seed, sizeof(seed));
  } else {
    randombytes_buf(seed, sizeof(seed));
    p.putBytes("sk_seed", seed, sizeof(seed));
  }
  p.end();
  crypto_sign_seed_keypair(pk, sk, seed);
  sodium_memzero(seed, sizeof(seed));
  toHex(pk, sizeof(pk), pkHex);
  unsigned char flagged[1 + crypto_sign_PUBLICKEYBYTES], h[32];
  flagged[0] = 0x00;                                  // Sui signature-scheme flag: Ed25519
  memcpy(flagged + 1, pk, sizeof(pk));
  crypto_generichash(h, sizeof(h), flagged, sizeof(flagged), nullptr, 0);   // BLAKE2b-256
  addrHex[0] = '0'; addrHex[1] = 'x';
  toHex(h, sizeof(h), addrHex + 2);
  ready = true;
  return true;
}

// json holds a complete object "{...}" (already containing "pk"). Appends
// ,"sig":"<128 hex>" before the closing brace. false if it does not fit.
static bool signJson(char* json, size_t cap) {
  size_t n = strlen(json);
  const size_t extra = 8 + 128 + 2;                   // ,"sig":"  hex  "}
  if (!ready || n < 2 || json[n - 1] != '}' || n - 1 + extra + 1 > cap) return false;
  static unsigned char msg[18 + 1024];
  if (sizeof(DOMAIN) + n > sizeof(msg)) return false;
  memcpy(msg, DOMAIN, sizeof(DOMAIN));                // includes the NUL
  memcpy(msg + sizeof(DOMAIN), json, n);
  unsigned char sig[crypto_sign_BYTES];
  crypto_sign_detached(sig, nullptr, msg, sizeof(DOMAIN) + n, sk);
  char sigHex[2 * crypto_sign_BYTES + 1];
  toHex(sig, sizeof(sig), sigHex);
  snprintf(json + n - 1, cap - (n - 1), ",\"sig\":\"%s\"}", sigHex);
  return true;
}

// ---- signed acknowledgements (v2.2) -------------------------------------------
// ack = {"id":..,"seq":..,"node":..,"epoch":..,"ts":..,"apk":"<64 hex>","sig":"<128 hex>"}
// sig = Ed25519(bridge ack key, "om2m-esp32-ack-v1\0" || <ack without the sig field>)
static const char ACK_DOMAIN[] = "om2m-esp32-ack-v1";   // + NUL = 18 bytes
static unsigned char ackKeys[16][crypto_sign_PUBLICKEYBYTES];
static int nAckKeys = 0;
static uint32_t acksRejected = 0;

static bool fromHex(const char* in, size_t n, unsigned char* out) {
  for (size_t i = 0; i < n; i++) {
    int v = 0;
    for (int k = 0; k < 2; k++) {
      char c = in[2 * i + k];
      int d = (c >= '0' && c <= '9') ? c - '0' : (c >= 'a' && c <= 'f') ? c - 'a' + 10
            : (c >= 'A' && c <= 'F') ? c - 'A' + 10 : -1;
      if (d < 0) return false;
      v = v * 16 + d;
    }
    out[i] = (unsigned char)v;
  }
  return true;
}

// "hex64,hex64,..." -> number of keys pinned
static int loadAckKeys(const char* csv) {
  nAckKeys = 0;
  const char* p = csv;
  while (*p && nAckKeys < 16) {
    while (*p == ',' || *p == ' ') p++;
    if (strlen(p) < 64) break;
    if (fromHex(p, 32, ackKeys[nAckKeys])) nAckKeys++;
    p += 64;
  }
  return nAckKeys;
}

// Verifies a raw ack. On success copies the SIGNED body ("{...}" without sig)
// into body; the caller parses only that copy, so nothing unsigned is used.
static bool verifyAck(const char* json, size_t n, char* body, size_t cap) {
  static const char SIG[] = ",\"sig\":\"";
  const size_t sl = sizeof(SIG) - 1;
  if (n < sl + 130 + 2) return false;
  size_t i = n - (sl + 128 + 2);                       // ,"sig":" must start exactly here
  if (memcmp(json + i, SIG, sl) != 0 || json[n - 2] != '"' || json[n - 1] != '}') return false;
  unsigned char sig[crypto_sign_BYTES];
  if (!fromHex(json + i + sl, crypto_sign_BYTES, sig)) return false;
  if (i + 2 > cap) return false;
  memcpy(body, json, i);
  body[i] = '}';
  body[i + 1] = 0;
  const char* a = strstr(body, "\"apk\":\"");
  if (!a || strstr(a + 1, "\"apk\":\"")) return false;   // exactly one apk field
  a += 7;
  if (strlen(a) < 65 || a[64] != '"') return false;
  unsigned char apk[crypto_sign_PUBLICKEYBYTES];
  if (!fromHex(a, 32, apk)) return false;
  bool pinned = false;
  for (int k = 0; k < nAckKeys && !pinned; k++) pinned = memcmp(apk, ackKeys[k], sizeof(apk)) == 0;
  if (!pinned) return false;
  static unsigned char msg[18 + 512];
  if (sizeof(ACK_DOMAIN) + i + 1 > sizeof(msg)) return false;
  memcpy(msg, ACK_DOMAIN, sizeof(ACK_DOMAIN));        // includes the NUL
  memcpy(msg + sizeof(ACK_DOMAIN), body, i + 1);
  return crypto_sign_verify_detached(sig, msg, sizeof(ACK_DOMAIN) + i + 1, apk) == 0;
}

}  // namespace devkey
