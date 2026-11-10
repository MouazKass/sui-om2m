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

}  // namespace devkey
