// ota_test.cpp - host test for the firmware's signed-update logic (ota_core.h, fw 2.4).
//
//   g++ -std=c++17 -Wall -Wextra -I stubs -o ota_test ota_test.cpp -lsodium && ./ota_test [vectors.txt]
//
// Signs manifests with libsodium (fixed seed), checks that ota_core accepts the
// genuine one and refuses forged, tampered, duplicated, wrong-domain, old,
// failed, foreign-target, oversized and bad-path ones; checks the streaming
// SHA-256; and walks the rollback state machine through NVS "reboots".
// argv[1]: write the genuine manifests here, so tests/test_ota.py can verify the
// C++-signed bytes with the Python reference (ota_manifest.py).
#include "Arduino.h"
#include "Preferences.h"
unsigned long g_virtual_ms = 0;
HostSerial Serial;
HostESP ESP;
std::map<std::string, uint32_t> g_nvs;
std::map<std::string, std::string> g_nvs_bytes;

#include "../../firmware/esp32_sensor_node/ota_core.h"
#include <string>

static int fails = 0, passes = 0;
static void check(const char* name, bool ok, const std::string& d = "") {
  printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", name, d.empty() ? "" : "  -- ", d.c_str());
  ok ? passes++ : fails++;
}
static std::string hex(const unsigned char* b, size_t n) {
  static const char* x = "0123456789abcdef";
  std::string s;
  for (size_t i = 0; i < n; i++) { s += x[b[i] >> 4]; s += x[b[i] & 15]; }
  return s;
}

struct Key { unsigned char pk[32], sk[64]; std::string pkHex; };
static Key mkKey(unsigned char fill) {
  Key k; unsigned char seed[32]; memset(seed, fill, sizeof(seed));
  crypto_sign_seed_keypair(k.pk, k.sk, seed);
  k.pkHex = hex(k.pk, 32);
  return k;
}
static std::string body(uint32_t v, const std::string& target, uint32_t size, const std::string& sha,
                        const std::string& path, const std::string& fpk, const char* kind = "om2m-fw") {
  char b[700];
  snprintf(b, sizeof(b),
           "{\"kind\":\"%s\",\"version\":%u,\"target\":\"%s\",\"size\":%u,\"sha256\":\"%s\","
           "\"path\":\"%s\",\"fpk\":\"%s\",\"ts\":1763300000}",
           kind, v, target.c_str(), size, sha.c_str(), path.c_str(), fpk.c_str());
  return b;
}
static std::string signWith(const std::string& b, const Key& k, const char* domain = "om2m-esp32-fw-v1") {
  std::string msg(domain, strlen(domain) + 1);
  msg += b;
  unsigned char sig[64];
  crypto_sign_detached(sig, nullptr, (const unsigned char*)msg.data(), msg.size(), k.sk);
  return b.substr(0, b.size() - 1) + ",\"sig\":\"" + hex(sig, 64) + "\"}";
}
static const char* verify(const std::string& raw, ota::Manifest& m) {
  return ota::parseVerify(raw.data(), raw.size(), m);
}
static std::string why(const char* r) { return r ? r : "accepted"; }

int main(int argc, char** argv) {
  if (sodium_init() < 0) { printf("sodium_init failed\n"); return 1; }
  Key rel = mkKey(0x42), rogue = mkKey(0x66);
  std::string keys = rel.pkHex;
  check("one firmware key pinned", ota::loadFwKeys(keys.c_str()) == 1);

  // a real image's digest
  std::string image(1000, '\0');
  for (size_t i = 0; i < image.size(); i++) image[i] = (char)(i * 7);
  unsigned char d[32];
  crypto_hash_sha256(d, (const unsigned char*)image.data(), image.size());
  std::string sha = hex(d, 32);

  std::string good = signWith(body(240, "all", 1000, sha, "/fw/fw-240.bin", rel.pkHex), rel);
  ota::Manifest m;
  const char* r = verify(good, m);
  check("genuine manifest verifies", r == nullptr, why(r));
  check("fields parsed", m.version == 240 && m.size == 1000 && sha == m.sha256 &&
                         !strcmp(m.path, "/fw/fw-240.bin") && !strcmp(m.target, "all"));
  check("genuine release accepted for install", ota::decide(m, "esp32-dht-01", 0, 0) == nullptr);
  r = verify(good + "\n", m);
  check("trailing newline (HTTP body) tolerated", r == nullptr, why(r));

  std::string forged = signWith(body(240, "all", 1000, sha, "/fw/fw-240.bin", rogue.pkHex), rogue);
  check("forged: signed by an unpinned key", why(verify(forged, m)) == "untrusted_key");
  std::string claim = signWith(body(240, "all", 1000, sha, "/fw/fw-240.bin", rel.pkHex), rogue);
  check("forged: claims the pinned key, signed by another", why(verify(claim, m)) == "bad_signature");
  std::string tampered = good;
  tampered.replace(tampered.find("\"size\":1000"), 11, "\"size\":1001");
  check("tampered after signing", why(verify(tampered, m)) == "bad_signature");
  std::string dev = signWith(body(240, "all", 1000, sha, "/fw/fw-240.bin", rel.pkHex), rel, "om2m-esp32-sig-v1");
  check("a device-domain signature is not a release", why(verify(dev, m)) == "bad_signature");
  std::string ack = signWith(body(240, "all", 1000, sha, "/fw/fw-240.bin", rel.pkHex), rel, "om2m-esp32-ack-v1");
  check("an ack-domain signature is not a release", why(verify(ack, m)) == "bad_signature");
  std::string dupb = body(240, "all", 1000, sha, "/fw/fw-240.bin", rel.pkHex);
  dupb.insert(dupb.size() - 1, ",\"version\":999");
  check("duplicate field refused even when signed", why(verify(signWith(dupb, rel), m)) == "bad_fields");
  check("unsigned refused", why(verify(body(240, "all", 1000, sha, "/fw/x.bin", rel.pkHex), m)) == "unsigned");
  check("wrong kind refused",
        why(verify(signWith(body(240, "all", 1000, sha, "/fw/x.bin", rel.pkHex, "other"), rel), m)) == "wrong_kind");

  auto dec = [&](uint32_t v, const std::string& t, uint32_t sz, const std::string& path,
                 uint32_t inst, uint32_t bad) {
    ota::Manifest mm;
    const char* rr = verify(signWith(body(v, t, sz, sha, path, rel.pkHex), rel), mm);
    if (rr) return std::string("verify:") + rr;
    return why(ota::decide(mm, "esp32-dht-01", inst, bad));
  };
  check("same version as installed: refused", dec(240, "all", 1000, "/fw/a.bin", 240, 0) == "not_newer");
  check("older version (rollback attack): refused", dec(239, "all", 1000, "/fw/a.bin", 240, 0) == "not_newer");
  check("version that rolled back before: refused", dec(241, "all", 1000, "/fw/a.bin", 240, 241) == "failed_before");
  check("newer than a failed one: accepted", dec(242, "all", 1000, "/fw/a.bin", 240, 241) == "accepted");
  check("for another device: refused", dec(250, "esp32-dht-02", 1000, "/fw/a.bin", 0, 0) == "not_for_this_device");
  check("for this device: accepted", dec(250, "esp32-dht-01", 1000, "/fw/a.bin", 0, 0) == "accepted");
  check("larger than an OTA slot: refused", dec(250, "all", 0x140001, "/fw/a.bin", 0, 0) == "bad_size");
  check("path outside /fw: refused", dec(250, "all", 1000, "/etc/passwd.bin", 0, 0) == "bad_path");
  check("path traversal: refused", dec(250, "all", 1000, "/fw/../x.bin", 0, 0) == "bad_path");

  // streaming hash
  ota::Manifest gm; verify(good, gm);
  ota::Hasher h; h.begin();
  for (size_t i = 0; i < image.size(); i += 333)
    h.update((const uint8_t*)image.data() + i, std::min<size_t>(333, image.size() - i));
  check("image streamed in chunks matches its SHA-256", h.matches(gm));
  std::string bad = image; bad[500] ^= 1;
  h.begin(); h.update((const uint8_t*)bad.data(), bad.size());
  check("one flipped bit is detected", !h.matches(gm));
  h.begin(); h.update((const uint8_t*)image.data(), 999);
  check("truncated image is detected", !h.matches(gm));

  // rollback state machine (NVS survives "reboots")
  const uint32_t SLOT_A = 0x10000, SLOT_B = 0x150000;
  g_nvs.clear();
  check("first boot: normal", ota::onBoot(SLOT_A) == ota::BOOT_NORMAL);
  ota::onInstalled(240, SLOT_B);
  check("boot 1 of the new image: on trial", ota::onBoot(SLOT_B) == ota::BOOT_TRIAL);
  check("healthy: kept, installed = 240", ota::onHealthy() && ota::load().ver == 240 && !ota::load().pend);
  check("later boots: normal", ota::onBoot(SLOT_B) == ota::BOOT_NORMAL);
  ota::onInstalled(241, SLOT_A);
  bool trials = true;
  for (int i = 0; i < OTA_MAX_TRIES; i++) trials &= ota::onBoot(SLOT_A) == ota::BOOT_TRIAL;
  check("a crashing image gets OTA_MAX_TRIES boots", trials);
  check("then it is rolled back", ota::onBoot(SLOT_A) == ota::BOOT_ROLLBACK);
  ota::State s = ota::load();
  check("after rollback: still 240, 241 marked failed", s.ver == 240 && s.bad == 241 && !s.pend);
  check("back on the old image: normal", ota::onBoot(SLOT_B) == ota::BOOT_NORMAL);
  ota::onInstalled(242, SLOT_A);
  check("bootloader already rolled back (old slot runs): no second switch",
        ota::onBoot(SLOT_B) == ota::BOOT_NORMAL && ota::load().bad == 242 && !ota::load().pend);
  check("healthy without a trial changes nothing", !ota::onHealthy() && ota::load().ver == 240);

  // device-ID guard: an OTA image built for another board must not rename this one
  g_nvs.clear(); g_nvs_bytes.clear();
  check("first USB flash records its DEVICE_ID", ota::idMatches("esp32-dht-01", false));
  check("same ID on a trial image: kept", ota::idMatches("esp32-dht-01", true));
  check("other board's image on trial: rejected", !ota::idMatches("esp32-dht-02", true));
  ota::onInstalled(300, SLOT_B);
  ota::onBoot(SLOT_B);
  check("rejected trial is rolled back and marked failed",
        ota::forceRollback() == ota::BOOT_ROLLBACK && ota::load().bad == 300 && !ota::load().pend);
  check("a deliberate USB reflash may change the ID", ota::idMatches("esp32-dht-02", false) &&
                                                      ota::idMatches("esp32-dht-02", true));

  if (argc > 1) {
    FILE* f = fopen(argv[1], "w");
    if (f) {
      fprintf(f, "%s %s\n", rel.pkHex.c_str(), good.c_str());
      fprintf(f, "%s %s\n", rel.pkHex.c_str(), signWith(body(7, "esp32-dht-01", 4096, sha, "/fw/fw-7.bin", rel.pkHex), rel).c_str());
      fclose(f);
    }
  }
  printf("ota_core host check: %d passed, %d failed\n", passes, fails);
  return fails ? 1 : 0;
}
