// flash_buffer.h - durable resend buffer (fw 2.3).
//
// Every reading is written to flash (LittleFS, the "spiffs" partition of the
// default 4 MB layout) BEFORE it is sent, and stays there until a bridge acks
// it. The bridges ack only once a quorum of the cluster's CSEs hold the reading
// on disk (esp32/pi/replicator.py), so a reading is always in at least one
// durable place: this buffer, or the cluster. It survives a board reboot or
// brown-out and an outage of FB_SLOTS readings (1440 = 2 h at 5 s).
//
//   /fb.dat  FB_SLOTS fixed slots: {magic, epoch, seq, len, crc32} + payload
//            (the signed JSON, sent again byte for byte). The CRC makes a slot
//            half-written by a power cut read as empty, never as garbage.
//   /fb.ack  per slot, the (epoch, seq) last acked there. A slot counts as
//            acked only if that pair equals its record's, so reusing a slot
//            can never make a new reading look acked. Written in batches
//            (FB_ACK_FLUSH_MS): after a reboot a few acked readings may be
//            sent again, which the bridges drop as duplicates.
//
// Sending: ONE sender, oldest first, at most FB_WINDOW unacked in flight, each
// re-sent after FB_RETRY_MS without an ack. A newer epoch is not sent while an
// older one still has unacked readings (epoch barrier): the bridges' replay
// floor rejects an older epoch once it has seen a newer one, so the backlog
// from before a reboot must arrive first. FB_WINDOW (16) is far below the
// bridges' seq_window (256), so in-epoch order never trips the floor either.
//
// Wear: one ~660-byte slot write per reading (LittleFS rewrites one 4 KB block,
// wear-levelled over ~350 blocks): about 50 erases per block per day at 5 s,
// i.e. years for 100k-cycle flash. Ack writes are batched.
#pragma once
#include <LittleFS.h>

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
#ifndef FB_ACK_FLUSH_MS
#define FB_ACK_FLUSH_MS 30000UL
#endif
#ifndef FB_PER_PASS
#define FB_PER_PASS 4
#endif
#ifndef PAYLOAD_LEN
#error "define PAYLOAD_LEN before including flash_buffer.h"
#endif

namespace fb {

static const uint32_t MAGIC = 0x53554932;          // "SUI2"
struct Hdr { uint32_t magic, epoch, seq, crc; uint16_t len, pad; };
struct AckRec { uint32_t epoch, seq; };
struct Idx { uint32_t epoch, seq, lastSent; uint16_t tries; uint8_t valid, acked, dirty; };
static const size_t REC = sizeof(Hdr) + PAYLOAD_LEN;

static Idx idx[FB_SLOTS];
static uint32_t wpos = 0;
static bool ready = false;
static bool ackDirty = false;
static unsigned long lastAckFlush = 0;
static uint32_t overwritten = 0, restored = 0, sentCount = 0;
static File data, acks;
static char rbuf[PAYLOAD_LEN];

static uint32_t crc32(const char* p, size_t n) {
  uint32_t c = 0xFFFFFFFFu;
  for (size_t i = 0; i < n; i++) {
    c ^= (uint8_t)p[i];
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
  }
  return ~c;
}

static bool older(const Idx& a, const Idx& b) {
  return a.epoch < b.epoch || (a.epoch == b.epoch && a.seq < b.seq);
}

static bool makeFile(const char* path, size_t size) {
  File f = LittleFS.open(path, "w");
  if (!f) return false;
  static uint8_t zero[512];
  for (size_t done = 0; done < size;) {
    size_t n = size - done < sizeof(zero) ? size - done : sizeof(zero);
    if (f.write(zero, n) != n) { f.close(); return false; }
    done += n;
  }
  f.close();
  return true;
}

static bool openSized(File& f, const char* path, size_t size) {
  if (LittleFS.exists(path)) {
    File t = LittleFS.open(path, "r");
    bool okSize = t && (size_t)t.size() == size;
    if (t) t.close();
    if (!okSize) LittleFS.remove(path);
  }
  if (!LittleFS.exists(path) && !makeFile(path, size)) return false;
  f = LittleFS.open(path, "r+");
  return (bool)f;
}

// Mount, open (creating on first boot), and rebuild the index. -> unacked count.
static uint32_t begin() {
  ready = false;
  restored = 0;
  memset(idx, 0, sizeof(idx));
  if (!LittleFS.begin(true)) {
    Serial.println("[fb] LittleFS mount failed: readings are NOT kept across a reboot");
    return 0;
  }
  if (!openSized(data, "/fb.dat", (size_t)FB_SLOTS * REC) ||
      !openSized(acks, "/fb.ack", (size_t)FB_SLOTS * sizeof(AckRec))) {
    Serial.println("[fb] cannot create the buffer files: readings are NOT kept across a reboot");
    return 0;
  }
  int best = -1;
  for (uint32_t i = 0; i < FB_SLOTS; i++) {
    Hdr h;
    AckRec a;
    data.seek(i * REC);
    if (data.read((uint8_t*)&h, sizeof(h)) != sizeof(h)) break;
    acks.seek(i * sizeof(AckRec));
    if (acks.read((uint8_t*)&a, sizeof(a)) != sizeof(a)) a = {0, 0};
    Idx& x = idx[i];
    x.valid = 0;
    if (h.magic == MAGIC && h.len > 0 && h.len < PAYLOAD_LEN) {
      data.read((uint8_t*)rbuf, h.len);
      if (crc32(rbuf, h.len) == h.crc) x.valid = 1;
    }
    if (!x.valid) continue;
    x.epoch = h.epoch;
    x.seq = h.seq;
    x.acked = (a.epoch == h.epoch && a.seq == h.seq) ? 1 : 0;
    if (!x.acked) restored++;
    if (best < 0 || older(idx[best], x)) best = (int)i;
  }
  wpos = best < 0 ? 0 : (uint32_t)(best + 1) % FB_SLOTS;
  ready = true;
  Serial.printf("[fb] flash buffer: %u slots, %lu unacked reading(s) restored\n",
                (unsigned)FB_SLOTS, (unsigned long)restored);
  return restored;
}

// Store a reading before it is sent. The oldest slot is reused; if it still
// held an unacked reading (buffer full for FB_SLOTS readings), that one is lost.
static void append(uint32_t epoch, uint32_t seq, const char* payload) {
  if (!ready) return;
  Idx& x = idx[wpos];
  if (x.valid && !x.acked) {
    overwritten++;
    Serial.printf("[fb] FULL: unacked e%lu s%lu overwritten (%lu so far)\n", (unsigned long)x.epoch,
                  (unsigned long)x.seq, (unsigned long)overwritten);
  }
  Hdr h;
  h.magic = MAGIC;
  h.epoch = epoch;
  h.seq = seq;
  h.len = (uint16_t)strnlen(payload, PAYLOAD_LEN - 1);
  h.pad = 0;
  h.crc = crc32(payload, h.len);
  data.seek(wpos * REC);
  data.write((const uint8_t*)&h, sizeof(h));
  data.write((const uint8_t*)payload, h.len);
  data.flush();
  x.epoch = epoch;
  x.seq = seq;
  x.lastSent = 0;
  x.tries = 0;
  x.valid = 1;
  x.acked = 0;
  x.dirty = 0;
  wpos = (wpos + 1) % FB_SLOTS;
}

// A signed ack arrived for (epoch, seq). -> true if it confirmed a buffered reading.
static bool ack(uint32_t epoch, uint32_t seq) {
  if (!ready) return false;
  for (uint32_t i = 0; i < FB_SLOTS; i++) {
    Idx& x = idx[i];
    if (x.valid && !x.acked && x.epoch == epoch && x.seq == seq) {
      x.acked = 1;
      x.dirty = 1;
      ackDirty = true;
      return true;
    }
  }
  return false;
}

static void flushAcks() {
  if (!ready || !ackDirty) return;
  for (uint32_t i = 0; i < FB_SLOTS; i++) {
    Idx& x = idx[i];
    if (!x.dirty) continue;
    AckRec a = {x.epoch, x.seq};
    acks.seek(i * sizeof(AckRec));
    acks.write((const uint8_t*)&a, sizeof(a));
    x.dirty = 0;
  }
  acks.flush();
  ackDirty = false;
}

static uint32_t unacked() {
  uint32_t n = 0;
  for (uint32_t i = 0; i < FB_SLOTS; i++)
    if (idx[i].valid && !idx[i].acked) n++;
  return n;
}

// Called every loop pass. Flushes ack state now and then and, while connected,
// sends what is due: oldest first, at most FB_WINDOW in flight, epoch barrier.
// publish() returns false if the client could not send (stop for this pass).
typedef bool (*PublishFn)(const char* payload);
static int service(unsigned long now, bool connected, PublishFn publish) {
  if (!ready) return 0;
  if (ackDirty && (now - lastAckFlush >= FB_ACK_FLUSH_MS)) {
    lastAckFlush = now;
    flushAcks();
  }
  if (!connected) return 0;
  uint32_t inflight = 0;
  bool haveOldest = false;
  uint32_t oldestEpoch = 0;
  for (uint32_t k = 0; k < FB_SLOTS; k++) {
    const Idx& x = idx[(wpos + k) % FB_SLOTS];
    if (!x.valid || x.acked) continue;
    if (!haveOldest) { haveOldest = true; oldestEpoch = x.epoch; }
    if (x.lastSent && now - x.lastSent < FB_RETRY_MS) inflight++;
  }
  if (!haveOldest) return 0;
  int sent = 0;
  for (uint32_t k = 0; k < FB_SLOTS && sent < FB_PER_PASS && inflight < FB_WINDOW; k++) {
    uint32_t i = (wpos + k) % FB_SLOTS;
    Idx& x = idx[i];
    if (!x.valid || x.acked) continue;
    if (x.epoch != oldestEpoch) break;                       // epoch barrier
    if (x.lastSent && now - x.lastSent < FB_RETRY_MS) continue;   // in flight
    Hdr h;
    data.seek(i * REC);
    if (data.read((uint8_t*)&h, sizeof(h)) != sizeof(h) || h.len >= PAYLOAD_LEN) { x.valid = 0; continue; }
    data.read((uint8_t*)rbuf, h.len);
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
