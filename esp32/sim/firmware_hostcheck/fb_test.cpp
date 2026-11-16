// fb_test.cpp - host test for the firmware's durable resend buffer
// (esp32/firmware/esp32_sensor_node/flash_buffer.h) on the in-memory LittleFS stub.
//
//   g++ -std=c++17 -Wall -Wextra -I stubs -o fb_test fb_test.cpp && ./fb_test
#include "Arduino.h"
unsigned long g_virtual_ms = 0;
HostSerial Serial;
HostESP ESP;

#define PAYLOAD_LEN 640
#define FB_SLOTS 32
#define FB_WINDOW 4
#define FB_PER_PASS 8
#include "../../firmware/esp32_sensor_node/flash_buffer.h"

#include <string>
#include <vector>

static int fails = 0, passes = 0;
static void check(const char* name, bool ok, const std::string& d = "") {
  printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", name, d.empty() ? "" : "  -- ", d.c_str());
  ok ? passes++ : fails++;
}

static std::vector<std::string> wire;
static bool pub(const char* p) { wire.push_back(p); return true; }
static std::string rd(uint32_t e, uint32_t s) {
  return "{\"epoch\":" + std::to_string(e) + ",\"seq\":" + std::to_string(s) + ",\"sig\":\"x\"}";
}
static void reading(uint32_t e, uint32_t s) { fb::append(e, s, rd(e, s).c_str()); }
static void ackAll() {
  for (auto& w : wire) {
    unsigned long e = 0, s = 0;
    sscanf(w.c_str(), "{\"epoch\":%lu,\"seq\":%lu", &e, &s);
    fb::ack(e, s);
  }
}
static void reboot() { fb::begin(); }

int main() {
  printf("flash buffer host test\n");
  fb::begin();

  // 1. readings taken offline are sent oldest first, at most FB_WINDOW in flight
  for (uint32_t s = 0; s < 10; s++) reading(1, s);
  fb::service(1000, false, pub);
  check("nothing is sent while disconnected", wire.empty());
  fb::service(1000, true, pub);
  check("window: only FB_WINDOW in flight", wire.size() == 4, std::to_string(wire.size()));
  check("oldest first", !wire.empty() && wire[0] == rd(1, 0) && wire[3] == rd(1, 3));
  ackAll();
  wire.clear();
  fb::service(1100, true, pub);
  check("acks open the window for the next ones", wire.size() == 4 && wire[0] == rd(1, 4));

  // 2. a reboot keeps every unacked reading; acks that were flushed stay acked
  fb::service(1100 + FB_ACK_FLUSH_MS, true, pub);      // flush acks of 0..3 (4..7 now in flight)
  wire.clear();
  reboot();
  check("reboot restores the unacked ones", fb::unacked() == 6, std::to_string(fb::unacked()));
  // 3. epoch barrier: the new power-up's readings wait for the old epoch's backlog
  reading(2, 0);
  reading(2, 1);
  fb::service(50000, true, pub);
  bool onlyOld = !wire.empty();
  for (auto& w : wire) onlyOld = onlyOld && w.find("\"epoch\":1") != std::string::npos;
  check("epoch barrier: old epoch first", onlyOld && wire[0] == rd(1, 4), wire.empty() ? "" : wire[0]);
  ackAll();
  wire.clear();
  fb::service(50100, true, pub);
  ackAll();
  wire.clear();
  fb::service(50200, true, pub);
  check("then the new epoch", wire.size() == 2 && wire[0] == rd(2, 0), std::to_string(wire.size()));
  ackAll();
  wire.clear();

  // 4. no ack -> re-sent after FB_RETRY_MS, not before
  reading(2, 2);
  fb::service(60000, true, pub);
  fb::service(60000 + FB_RETRY_MS - 1, true, pub);
  check("not re-sent before FB_RETRY_MS", wire.size() == 1);
  fb::service(60000 + FB_RETRY_MS, true, pub);
  check("re-sent after FB_RETRY_MS", wire.size() == 2 && wire[1] == rd(2, 2));
  ackAll();
  wire.clear();

  // 5. a full buffer reuses the oldest slot; acked slots are reused silently
  uint32_t before = fb::overwritten;
  for (uint32_t s = 100; s < 100 + FB_SLOTS; s++) reading(3, s);
  check("acked slots are reused without loss", fb::overwritten == before);
  reading(3, 999);
  check("an unacked slot overwritten only when full", fb::overwritten == before + 1);

  // 6. a power cut in the middle of a slot write: the slot reads as empty, not garbage
  {
    auto buf = g_fs()["/fb.dat"];
    uint32_t slot = (fb::wpos + FB_SLOTS - 1) % FB_SLOTS;          // the slot just written
    (*buf)[slot * fb::REC + sizeof(fb::Hdr) + 3] ^= 0x5A;          // corrupt its payload
    reboot();
    bool found = false;
    for (uint32_t i = 0; i < FB_SLOTS; i++)
      if (fb::idx[i].valid && fb::idx[i].epoch == 3 && fb::idx[i].seq == 999) found = true;
    check("a torn slot (bad CRC) is ignored", !found);
  }

  // 7. a slot reused for a NEW reading is never taken for the old acked one
  {
    g_fs().clear();
    fb::begin();
    reading(5, 0);
    fb::ack(5, 0);
    fb::service(200000 + FB_ACK_FLUSH_MS, false, pub);   // ack persisted for slot 0
    for (uint32_t s = 1; s < FB_SLOTS; s++) { reading(5, s); fb::ack(5, s); }
    reading(5, 500);                                       // reuses slot 0, unacked
    reboot();                                              // its ack record still says (5,0)
    check("reused slot is unacked after reboot", fb::unacked() >= 1, std::to_string(fb::unacked()));
  }

  // 8. mount failure: buffer disabled, nothing crashes
  g_fs_mount_fails() = true;
  check("mount failure -> 0 restored, no crash", fb::begin() == 0 && !fb::ready);
  reading(9, 0);
  check("append is a no-op when disabled", fb::service(1, true, pub) == 0);
  g_fs_mount_fails() = false;

  printf("flash buffer: %d passed, %d failed\n", passes, fails);
  return fails ? 1 : 0;
}
