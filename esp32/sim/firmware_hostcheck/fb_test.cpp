// fb_test.cpp - host test for the firmware's durable resend buffer
// (esp32/firmware/esp32_sensor_node/flash_buffer.h) on a NOR-flash model of
// the data partition (stubs/esp_partition.h: sector erase only, writes clear
// bits only). 2.3.0 was tested on an in-memory file system that allowed
// in-place rewrites and so missed that the real LittleFS ran out of space (2.4);
// the flash model here fails any design that programs a bit back to 1.
//
//   g++ -std=c++17 -Wall -Wextra -I stubs -o fb_test fb_test.cpp && ./fb_test
#include "Arduino.h"
unsigned long g_virtual_ms = 0;
HostSerial Serial;
HostESP ESP;

#define PAYLOAD_LEN 640
#define FB_SLOTS 32          // rounds up to whole sectors: 36 slots of 6 per sector
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
  printf("flash buffer host test (slot %u B, %u per sector, %u slots)\n", (unsigned)fb::SLOT,
         (unsigned)fb::SPS, (unsigned)fb::SLOTS);
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

  // 2. a reboot keeps every unacked reading; acks are written at once and stay acked
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

  // 5. at least FB_SLOTS unacked readings are always kept (from any write
  //    position); past that the oldest go, at most one sector's worth at a time
  uint32_t before = fb::overwritten;
  for (uint32_t s = 100; s < 100 + FB_SLOTS; s++) reading(3, s);
  check("FB_SLOTS unacked readings kept without loss", fb::overwritten == before,
        std::to_string(fb::overwritten - before) + " lost");
  uint32_t extra = 0;
  while (fb::overwritten == before && extra < fb::nslots) reading(3, 900 + extra++);
  uint32_t lost = fb::overwritten - before;
  check("full ring: the oldest go, at most one sector at a time", lost >= 1 && lost <= fb::SPS,
        std::to_string(lost) + " lost after " + std::to_string(FB_SLOTS + extra) + " readings");
  reading(3, 999);
  reboot();
  bool newestKept = false;
  for (uint32_t i = 0; i < fb::nslots; i++)
    if (fb::idx[i].valid && fb::idx[i].epoch == 3 && fb::idx[i].seq == 999) newestKept = true;
  check("the newest reading survives the wrap and a reboot", newestKept);

  // 6. a power cut in the middle of a slot write: the slot reads as empty, not garbage
  {
    uint32_t slot = (fb::wpos + fb::nslots - 1) % fb::nslots;          // the slot just written
    g_flash()[fb::slotOff(slot) + fb::PAY_OFF + 3] &= 0x0F;           // a half-programmed byte
    reboot();
    bool found = false;
    for (uint32_t i = 0; i < fb::nslots; i++)
      if (fb::idx[i].valid && fb::idx[i].epoch == 3 && fb::idx[i].seq == 999) found = true;
    check("a torn slot (bad CRC) is ignored", !found);
    reading(4, 0);                                                     // must not program over it
    reboot();
    bool ok = false;
    for (uint32_t i = 0; i < fb::nslots; i++)
      if (fb::idx[i].valid && fb::idx[i].epoch == 4 && fb::idx[i].seq == 0) ok = true;
    check("the next reading after a torn slot is stored intact", ok);
  }

  // 7. a slot reused for a NEW reading never inherits the old reading's ack
  {
    std::fill(g_flash().begin(), g_flash().end(), 0xFF);
    fb::begin();
    for (uint32_t s = 0; s < fb::nslots; s++) { reading(5, s); fb::ack(5, s); }
    reading(5, 500);                                       // reuses slot 0 (sector erased)
    reboot();
    check("reused slot is unacked after reboot", fb::unacked() == 1, std::to_string(fb::unacked()));
  }

  // 8. the flash rules held throughout, and wear is one erase per sector's worth of readings
  check("never programs a bit from 0 to 1 (no write without erase)", g_flash_violations() == 0,
        std::to_string(g_flash_violations()));
  {
    std::fill(g_flash().begin(), g_flash().end(), 0xFF);
    fb::begin();
    uint32_t e0 = g_flash_erases();
    for (uint32_t s = 0; s < 10 * fb::nslots; s++) { reading(6, s); fb::ack(6, s); }
    uint32_t per = g_flash_erases() - e0;
    check("wear: one sector erase per SPS readings", per == 10 * fb::nslots / fb::SPS,
          std::to_string(per) + " erases for " + std::to_string(10 * fb::nslots) + " readings");
  }

  // 9. no data partition: buffer disabled, nothing crashes
  g_part_missing() = true;
  check("no partition -> 0 restored, no crash", fb::begin() == 0 && !fb::ready);
  reading(9, 0);
  check("append is a no-op when disabled", fb::service(1, true, pub) == 0);
  g_part_missing() = false;

  printf("flash buffer: %d passed, %d failed\n", passes, fails);
  return fails ? 1 : 0;
}
