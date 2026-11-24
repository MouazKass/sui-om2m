// flash_buffer.h - durable resend buffer (fw 2.3; raw flash slots since 2.4.1).
//
// Every reading is written to flash BEFORE it is sent, and stays there until a
// bridge acks it. The bridges ack only once a quorum of the cluster's CSEs hold
// the reading on disk (esp32/pi/replicator.py), so a reading is always in at
// least one durable place: this buffer, or the cluster. It survives a board
// reboot or brown-out and an outage of FB_SLOTS readings (1440 = 2 h at 5 s).
//
// Storage: the raw "spiffs" data partition of the default 4 MB layout, used as
// a ring of fixed slots with NO file system. (2.3/2.4 kept one big LittleFS file
// and rewrote slots in place; LittleFS files are copy-on-write to the end, so
// one slot write needed ~a file's worth of free space and failed on the first
// real board with "No more free space". Raw slots fix that and the wear.)
//
//   sector (4 KB) = SPS slots of SLOT bytes:  Hdr | ack word | payload
//   Hdr    {magic, epoch, seq, crc, len}; the CRC covers epoch, seq, len and
//          the payload, so a slot torn by a power cut reads as empty.
//   ack    0xFFFFFFFF (erased) = not acked; programmed to 0 when a bridge acks.
//          NOR flash can always clear bits without an erase, so an ack is one
//          4-byte write, done at once, never batched.
//
// A slot is only ever written while erased. The sector at the write position
// is erased just before its first slot is used; that drops the SPS oldest
// slots at once. The ring has one spare sector, so at least FB_SLOTS unacked
// readings are always kept; past that, the oldest are lost a sector at a time
// (counted in `overwritten`).
//
// Sending: ONE sender, oldest first, at most FB_WINDOW unacked in flight, each
// re-sent after FB_RETRY_MS without an ack. A newer epoch is not sent while an
// older one still has unacked readings (epoch barrier): the bridges' replay
// floor rejects an older epoch once it has seen a newer one, so the backlog
// from before a reboot must arrive first. FB_WINDOW (16) is far below the
// bridges' seq_window (256), so in-epoch order never trips the floor either.
//
// Wear: one sector erase per SPS readings, spread evenly over the ring's
// sectors: at 5 s, 1446 slots in 241 sectors, each sector is erased about once
// per 2 h lap (12 a day), i.e. decades for 100k-cycle flash. The default
// layout's data partition (1.375 MB, 352 sectors) holds the ring.
#pragma once
#include <esp_partition.h>

#ifndef FLASH_BUFFER
#define FLASH_BUFFER 1
#endif
#ifndef FB_SLOTS
#define FB_SLOTS 1440               // 2 h at PUBLISH_INTERVAL_MS = 5 s
#endif
#ifndef FB_WINDOW
#define FB_WINDOW 16
#endif
#ifndef FB_RETRY_MS
#define FB_RETRY_MS 15000UL
#endif
#ifndef FB_PER_PASS
#define FB_PER_PASS 4
#endif
#ifndef PAYLOAD_LEN
#error "define PAYLOAD_LEN before including flash_buffer.h"
#endif

namespace fb {

static const uint32_t MAGIC = 0x53554933;          // "SUI3" (the old LittleFS data is never misread)
static const uint32_t SECTOR = 4096;
struct Hdr { uint32_t magic, epoch, seq, crc; uint16_t len, pad; };
struct Idx { uint32_t epoch, seq, lastSent; uint16_t tries; uint8_t valid, acked; };
static const uint32_t ACK_OFF = sizeof(Hdr);                 // 20
static const uint32_t PAY_OFF = ACK_OFF + 4;                 // 24
static const uint32_t SLOT = (PAY_OFF + PAYLOAD_LEN + 3) & ~3u;
static const uint32_t SPS = SECTOR / SLOT;                   // slots per sector
static_assert(SPS >= 1, "PAYLOAD_LEN too large for a 4 KB sector");
// Whole sectors, plus one spare: the sector erased ahead of the write position
// drops up to SPS-1 slots early, so the spare keeps the promise that at least
// FB_SLOTS unacked readings are always held.
static const uint32_t SLOTS = ((FB_SLOTS + SPS - 1) / SPS + 1) * SPS;

static Idx idx[SLOTS];
static uint32_t nslots = 0;          // usable slots (SLOTS, or fewer if the partition is small)
static uint32_t wpos = 0;
static bool ready = false;
static uint32_t overwritten = 0, restored = 0, sentCount = 0, erases = 0;
static const esp_partition_t* part = nullptr;
static char rbuf[PAYLOAD_LEN];

static uint32_t slotOff(uint32_t i) { return (i / SPS) * SECTOR + (i % SPS) * SLOT; }

static uint32_t crc32(uint32_t c, const void* p, size_t n) {
  const uint8_t* b = (const uint8_t*)p;
  c = ~c;
  for (size_t i = 0; i < n; i++) {
    c ^= b[i];
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
  }
  return ~c;
}
static uint32_t recCrc(uint32_t epoch, uint32_t seq, uint16_t len, const char* payload) {
  uint32_t c = crc32(0, &epoch, 4);
  c = crc32(c, &seq, 4);
  c = crc32(c, &len, 2);
  return crc32(c, payload, len);
}

static bool older(const Idx& a, const Idx& b) {
  return a.epoch < b.epoch || (a.epoch == b.epoch && a.seq < b.seq);
}

// Read and verify slot i. -> true and fills h/rbuf if it holds a whole record.
static bool load(uint32_t i, Hdr& h, uint32_t* ackw) {
  if (esp_partition_read(part, slotOff(i), &h, sizeof(h)) != ESP_OK) return false;
  if (h.magic != MAGIC || h.len == 0 || h.len >= PAYLOAD_LEN) return false;
  if (esp_partition_read(part, slotOff(i) + PAY_OFF, rbuf, h.len) != ESP_OK) return false;
  if (recCrc(h.epoch, h.seq, h.len, rbuf) != h.crc) return false;
  if (ackw && esp_partition_read(part, slotOff(i) + ACK_OFF, ackw, 4) != ESP_OK) *ackw = 0xFFFFFFFFu;
  return true;
}

static bool blank(uint32_t i) {
  uint32_t w[64];
  for (uint32_t off = 0; off < SLOT; off += sizeof(w)) {
    uint32_t n = SLOT - off < sizeof(w) ? SLOT - off : sizeof(w);
    if (esp_partition_read(part, slotOff(i) + off, w, n) != ESP_OK) return false;
    for (uint32_t k = 0; k < n / 4; k++)
      if (w[k] != 0xFFFFFFFFu) return false;
  }
  return true;
}

// Find the partition and rebuild the index. -> unacked count.
static uint32_t begin() {
  ready = false;
  restored = 0;
  memset(idx, 0, sizeof(idx));
  part = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_SPIFFS, nullptr);
  if (!part) {
    Serial.println("[fb] no data partition: readings are NOT kept across a reboot");
    return 0;
  }
  uint32_t sectors = part->size / SECTOR;
  nslots = sectors * SPS < SLOTS ? sectors * SPS : SLOTS;
  if (nslots < SPS * 2) {
    Serial.println("[fb] data partition too small: readings are NOT kept across a reboot");
    return 0;
  }
  int best = -1;
  for (uint32_t i = 0; i < nslots; i++) {
    Hdr h;
    uint32_t ackw = 0xFFFFFFFFu;
    Idx& x = idx[i];
    if (!load(i, h, &ackw)) continue;
    x.valid = 1;
    x.epoch = h.epoch;
    x.seq = h.seq;
    x.acked = ackw != 0xFFFFFFFFu ? 1 : 0;
    if (!x.acked) restored++;
    if (best < 0 || older(idx[best], x)) best = (int)i;
  }
  wpos = best < 0 ? 0 : (uint32_t)(best + 1) % nslots;
  ready = true;
  Serial.printf("[fb] flash buffer: %u slots (%u per sector), %lu unacked reading(s) restored\n",
                (unsigned)nslots, (unsigned)SPS, (unsigned long)restored);
  return restored;
}

// Erase the sector holding slot i (its first slot must be i). Readings still
// unacked in it are lost: only possible when the ring is full.
static void eraseSectorAt(uint32_t i) {
  for (uint32_t k = i; k < i + SPS && k < nslots; k++) {
    Idx& x = idx[k];
    if (x.valid && !x.acked) {
      overwritten++;
      Serial.printf("[fb] FULL: unacked e%lu s%lu overwritten (%lu so far)\n", (unsigned long)x.epoch,
                    (unsigned long)x.seq, (unsigned long)overwritten);
    }
    x = Idx{};
  }
  esp_partition_erase_range(part, (i / SPS) * SECTOR, SECTOR);
  erases++;
}

// Store a reading before it is sent.
static void append(uint32_t epoch, uint32_t seq, const char* payload) {
  if (!ready) return;
  if (wpos % SPS == 0) {
    eraseSectorAt(wpos);
  } else if (!blank(wpos)) {
    // half-used sector whose next slot is not erased (e.g. a torn write):
    // never program over it, move on to the next sector
    wpos = (wpos / SPS + 1) * SPS % nslots;
    eraseSectorAt(wpos);
  }
  Hdr h;
  h.magic = MAGIC;
  h.epoch = epoch;
  h.seq = seq;
  h.len = (uint16_t)strnlen(payload, PAYLOAD_LEN - 1);
  h.pad = 0xFFFF;
  h.crc = recCrc(epoch, seq, h.len, payload);
  uint32_t plen = (h.len + 3u) & ~3u;                   // whole words; the tail stays 0xFF
  memset(rbuf, 0xFF, plen);
  memcpy(rbuf, payload, h.len);
  esp_partition_write(part, slotOff(wpos) + PAY_OFF, rbuf, plen);   // payload first,
  esp_partition_write(part, slotOff(wpos), &h, sizeof(h));          // header (magic) last
  Idx& x = idx[wpos];
  x = Idx{};
  x.epoch = epoch;
  x.seq = seq;
  x.valid = 1;
  wpos = (wpos + 1) % nslots;
}

// A signed ack arrived for (epoch, seq). -> true if it confirmed a buffered reading.
static bool ack(uint32_t epoch, uint32_t seq) {
  if (!ready) return false;
  for (uint32_t i = 0; i < nslots; i++) {
    Idx& x = idx[i];
    if (x.valid && !x.acked && x.epoch == epoch && x.seq == seq) {
      static const uint32_t zero = 0;
      esp_partition_write(part, slotOff(i) + ACK_OFF, &zero, 4);   // clears bits only: no erase
      x.acked = 1;
      return true;
    }
  }
  return false;
}

static uint32_t unacked() {
  uint32_t n = 0;
  for (uint32_t i = 0; i < nslots; i++)
    if (idx[i].valid && !idx[i].acked) n++;
  return n;
}

// Called every loop pass. While connected, sends what is due: oldest first, at
// most FB_WINDOW in flight, epoch barrier. publish() returns false if the
// client could not send (stop for this pass).
typedef bool (*PublishFn)(const char* payload);
static int service(unsigned long now, bool connected, PublishFn publish) {
  if (!ready || !connected) return 0;
  uint32_t inflight = 0;
  bool haveOldest = false;
  uint32_t oldestEpoch = 0;
  for (uint32_t k = 0; k < nslots; k++) {
    const Idx& x = idx[(wpos + k) % nslots];
    if (!x.valid || x.acked) continue;
    if (!haveOldest) { haveOldest = true; oldestEpoch = x.epoch; }
    if (x.lastSent && now - x.lastSent < FB_RETRY_MS) inflight++;
  }
  if (!haveOldest) return 0;
  int sent = 0;
  for (uint32_t k = 0; k < nslots && sent < FB_PER_PASS && inflight < FB_WINDOW; k++) {
    uint32_t i = (wpos + k) % nslots;
    Idx& x = idx[i];
    if (!x.valid || x.acked) continue;
    if (x.epoch != oldestEpoch) break;                       // epoch barrier
    if (x.lastSent && now - x.lastSent < FB_RETRY_MS) continue;   // in flight
    Hdr h;
    if (!load(i, h, nullptr)) { x.valid = 0; continue; }
    rbuf[h.len] = 0;
    if (!publish(rbuf)) break;
    if (x.lastSent) Serial.printf("[fb] resend e%lu s%lu (try %u)\n", (unsigned long)x.epoch,
                                  (unsigned long)x.seq, (unsigned)x.tries + 1);
    x.lastSent = now ? now : 1;
    x.tries++;
    inflight++;
    sent++;
    sentCount++;
  }
  return sent;
}

}  // namespace fb
