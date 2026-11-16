"""
flash_buffer_sim.py - the simulator's model of the firmware's durable resend
buffer (esp32/firmware/esp32_sensor_node/flash_buffer.h, fw 2.3).

Same rules: every reading is stored BEFORE it is sent and kept until a bridge
acks it; one sender, oldest first, at most `window` unacked in flight, re-sent
after `retry_s`; a newer epoch is not sent while an older one has unacked
readings (epoch barrier, for the bridges' replay floor); `slots` readings at
most, the oldest overwritten when full. The file (JSON, written atomically)
stands in for LittleFS: it survives a simulated power cycle (a new process
with the same --flash-buffer path and --state-file).
"""
import json
import os
import threading
import time


class FlashBuffer:
    def __init__(self, path, slots=1440, window=16, retry_s=15.0, save_every_s=1.0):
        self.path, self.slots, self.window, self.retry_s = path, slots, window, retry_s
        self.save_every_s = save_every_s
        self.lock = threading.Lock()
        self.recs = []            # oldest first: [epoch, seq, payload, acked]
        self.sent_at = {}         # (epoch, seq) -> last send time (RAM only, like the firmware)
        self.overwritten = 0
        self._dirty, self._saved_at = False, 0.0
        if path and os.path.exists(path):
            with open(path) as f:
                self.recs = [list(r) for r in json.load(f).get("recs", [])]
        self.restored = sum(1 for r in self.recs if not r[3])

    def _save(self, force=False):
        if not self.path or not (self._dirty or force):
            return
        now = time.time()
        if not force and now - self._saved_at < self.save_every_s:
            return
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"recs": self.recs}, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)
        self._dirty, self._saved_at = False, now

    def append(self, epoch, seq, payload):
        with self.lock:
            self.recs.append([epoch, seq, payload, False])
            while len(self.recs) > self.slots:
                old = self.recs.pop(0)
                if not old[3]:
                    self.overwritten += 1
            self._dirty = True
            self._save(force=True)          # the reading itself is durable before it is sent

    def has_epoch(self, epoch):
        with self.lock:
            return any(r[0] == epoch for r in self.recs)

    def ack(self, epoch, seq):
        with self.lock:
            for r in self.recs:
                if r[0] == epoch and r[1] == seq and not r[3]:
                    r[3] = True
                    self._dirty = True      # ack state: batched, like the firmware
                    self.sent_at.pop((epoch, seq), None)
                    return True
        return False

    def unacked(self):
        with self.lock:
            return sum(1 for r in self.recs if not r[3])

    def service(self, publish, now=None):
        """Send what is due. publish(payload) -> bool. Returns [(epoch, seq, resend, payload)]."""
        now = time.time() if now is None else now
        out = []
        with self.lock:
            self._save()
            pending = [r for r in self.recs if not r[3]]
            if not pending:
                return out
            barrier = pending[0][0]
            inflight = sum(1 for r in pending if now - self.sent_at.get((r[0], r[1]), -1e9) < self.retry_s)
            todo = []
            for r in pending:
                if r[0] != barrier or inflight + len(todo) >= self.window:
                    break
                k = (r[0], r[1])
                if now - self.sent_at.get(k, -1e9) < self.retry_s:
                    continue
                todo.append((k, r[2]))
        for k, payload in todo:
            if not publish(payload):
                break
            with self.lock:
                resend = k in self.sent_at
                self.sent_at[k] = now
            out.append((k[0], k[1], resend, payload))
        return out

    def close(self):
        with self.lock:
            self._save(force=True)
