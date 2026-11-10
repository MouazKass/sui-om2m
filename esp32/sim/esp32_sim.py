#!/usr/bin/env python3
"""
esp32_sim.py - stands in for a real ESP32 until the hardware arrives.

Speaks exactly what firmware/esp32_sensor_node.ino (v2) speaks, and moves
across the cluster by the same rules: the Selector class below is a line-by-line
port of firmware/esp32_sensor_node/cluster.h, and tests/test_selector.py runs
both against sim/selector_vectors.txt.

  sensors/<id>/telemetry  {"v":2,"id","epoch","boot","seq","ts","up_ms","rssi","via",
                           "temperature","humidity","light_raw","light_pct"}
  sensors/<id>/status     retained "online" per connection (session "<epoch>.<n>"),
                          Last Will "offline" with the same session
  sensors/<id>/ack        (subscribed) per-reading acks from the bridges
  om2m/cluster/brokers    (subscribed) retained membership, learned at run time

Cluster behaviour: home broker first; on failure the next broker at once, each
failed broker backing off (bounded); readings taken while detached are buffered
and re-sent after re-attaching unless a bridge acked them; return home only after
home answered probes for --home-stable seconds.

Examples
  python3 esp32_sim.py --device esp32-dht-01 --brokers rpi1=10.25.96.200:1883,rpi2=10.25.96.201:1883 --home rpi2
  python3 esp32_sim.py --device esp32-dht-01 --host 10.25.96.201        (single broker, v1-style)

Fault injection: --malformed-every N, --range-every N, --replay-every N (re-send
the previous reading = a duplicate), --v1 (legacy v1 payloads).
SIGTERM/SIGINT = graceful offline; SIGKILL = power loss (broker fires Last Will);
SIGUSR1 = stop taking readings, wait (--drain s) until every reading is acked, then
graceful offline (lets a test check completeness exactly).
"""

import argparse
import json
import math
import os
import random
import re
import secrets
import signal
import socket
import sys
import threading
import time

import paho.mqtt.client as mqtt

BROKERS_TOPIC = "om2m/cluster/brokers"
LABEL_RE = re.compile(r"^[a-z0-9-]{1,15}$")
HOST_RE = re.compile(r"^[A-Za-z0-9.-]{1,39}$")
MAX_BROKERS = 8


def now_ms():
    return int(time.monotonic() * 1000)


# ---------------------------------------------------------------------------
# Selector - a port of cluster.h (keep the two in step; see selector_vectors.txt)
# ---------------------------------------------------------------------------
class Broker:
    def __init__(self, label, host, port, seed):
        self.label, self.host, self.port, self.seed = label, host, port, seed
        self.alive, self.failures, self.retry_at = True, 0, 0


class Selector:
    def __init__(self, base=1000, mx=60000, probe=30000, stable=120000):
        self.b, self.home, self.current = [], -1, -1
        self.base, self.max, self.probe_ms, self.stable_ms = base, mx, probe, stable
        self.last_probe, self.home_ok_since, self.home_ok = 0, 0, False

    def find(self, label):
        return next((i for i, x in enumerate(self.b) if x.label == label), -1)

    def add(self, label, host, port, seed):
        if not LABEL_RE.match(label) or not HOST_RE.match(host) or not 0 < port < 65536:
            return -1
        i = self.find(label)
        if i < 0:
            if len(self.b) >= MAX_BROKERS:
                return -1
            self.b.append(Broker(label, host, port, seed))
            i = len(self.b) - 1
        x = self.b[i]
        if x.host != host or x.port != port:
            x.host, x.port, x.failures, x.retry_at = host, port, 0, 0
        x.seed = x.seed or seed
        return i

    def _entries(self, text, seed, prefix, listed=None):
        acc = 0
        for tok in text.split(","):
            if "=" not in tok:
                continue
            label, rest = tok.split("=", 1)
            parts = rest.split(":")
            if len(parts) < 2:
                continue
            host, alive = parts[0], (int(parts[2]) != 0 if len(parts) > 2 and parts[2].lstrip("-").isdigit() else True)
            try:
                port = int(parts[1])
            except ValueError:
                continue
            if not 0 < port <= 65535:
                continue
            if not seed and prefix and not host.startswith(prefix):
                continue
            i = self.add(label, host, port, seed)
            if i < 0:
                continue
            if not seed:
                self.b[i].alive = alive
            if listed is not None:
                listed.add(i)
            acc += 1
        return acc

    def add_seeds(self, text):
        return self._entries(text, True, "")

    def set_home(self, label):
        self.home = self.find(label)
        return self.home >= 0

    def next(self, now):
        if not self.b:
            return -1
        n, start = len(self.b), (self.home if self.home >= 0 else 0)
        for want_alive in (True, False):
            for k in range(n):
                i = (start + k) % n
                if self.b[i].alive != want_alive or self.b[i].retry_at > now:
                    continue
                return i
        return -1

    def wait_ms(self, now):
        if not self.b:
            return 1000
        if any(x.retry_at <= now for x in self.b):
            return 0
        return min(x.retry_at - now for x in self.b)

    def on_connected(self, i, now):
        self.current = i
        self.b[i].failures, self.b[i].retry_at = 0, 0
        self.last_probe, self.home_ok, self.home_ok_since = now, False, 0

    def on_failed(self, i, now):
        if i < 0 or i >= len(self.b):
            return
        if self.current == i:
            self.current = -1
        x = self.b[i]
        x.failures = min(x.failures + 1, 16)
        backoff = self.base
        k = 1
        while k < x.failures and backoff < self.max:
            backoff *= 2
            k += 1
        x.retry_at = now + min(backoff, self.max)
        if i == self.home:
            self.home_ok, self.home_ok_since = False, 0

    def penalize(self, i, now, ms):
        self.on_failed(i, now)
        if 0 <= i < len(self.b) and self.b[i].retry_at < now + ms:
            self.b[i].retry_at = now + ms

    def probe_due(self, now):
        return (self.current >= 0 and self.home >= 0 and self.current != self.home
                and now - self.last_probe >= self.probe_ms)

    def on_home_probe(self, ok, now):
        self.last_probe = now
        if not ok or (self.home >= 0 and (not self.b[self.home].alive or self.b[self.home].retry_at > now)):
            self.home_ok, self.home_ok_since = False, 0
            return
        if not self.home_ok:
            self.home_ok, self.home_ok_since = True, now

    def should_return_home(self, now):
        return (self.current >= 0 and self.home >= 0 and self.current != self.home and self.home_ok
                and self.b[self.home].retry_at <= now and now - self.home_ok_since >= self.stable_ms)

    def learn(self, payload, prefix):
        if not payload.startswith("v1;"):
            return -1
        rest = payload[3:]
        if ";" not in rest:
            return -1
        listed = set()
        acc = self._entries(rest.split(";", 1)[1], False, prefix, listed)
        for i, x in enumerate(self.b):
            if i not in listed and not x.seed:
                x.alive = False
        return acc


def compare_session(a, b):
    def key(s):
        m = re.match(r"^(\d+)\.(\d+)$", s or "")
        return (int(m.group(1)), int(m.group(2))) if m else None
    ka, kb = key(a), key(b)
    if ka is None and kb is None:
        return 0
    if ka is None:
        return -1
    if kb is None:
        return 1
    return (ka > kb) - (ka < kb)


# ---------------------------------------------------------------------------
# the simulated sensor
# ---------------------------------------------------------------------------
def make_client(cid):
    try:
        c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=cid, clean_session=True)
    except AttributeError:
        c = mqtt.Client(client_id=cid, clean_session=True)
    return c


class Sensor:
    def __init__(self, a):
        self.a = a
        self.dev = a.device
        self.t_tele, self.t_status, self.t_ack = (f"sensors/{a.device}/telemetry",
                                                  f"sensors/{a.device}/status", f"sensors/{a.device}/ack")
        self.sel = Selector(int(a.backoff_base * 1000), int(a.backoff_max * 1000),
                            int(a.home_probe * 1000), int(a.home_stable * 1000))
        seeds = a.brokers or f"home={a.host}:{a.port}"
        self.sel.add_seeds(seeds)
        home = a.home or ("home" if not a.brokers else seeds.split("=", 1)[0])
        if not self.sel.set_home(home):
            sys.exit(f"--home {home} is not in the broker list")
        self.epoch = self._next_epoch()
        self.boot = secrets.token_hex(4)
        self.conn_count = 0
        self.session = ""
        self.client = None
        self.connected = threading.Event()
        self.lost = threading.Event()
        self.lock = threading.Lock()
        self.slots = {}          # seq -> [payload, acked]
        self.seq = 0
        self.conn_start_seq = 0
        self.ack_wait_until = 0
        self.resend_cursor = None
        self.start = time.time()
        self.last_payload = None
        self.out_lock = threading.Lock()
        self.first_unacked_pub = 0.0       # first publish since the last ack (0 = none)

    # NVS: epoch +1 per power-up
    def _next_epoch(self):
        p = self.a.state_file
        if not p:
            return max(1, int(time.time()) - 1_700_000_000)
        try:
            e = json.load(open(p)).get("epoch", 0)
        except (OSError, ValueError):
            e = 0
        e += 1
        with open(p, "w") as f:
            json.dump({"epoch": e}, f)
        return e

    def out(self, kind, text):
        if self.a.quiet and kind not in ("event",):
            return
        with self.out_lock:
            print(f"[{self.dev}] {kind:12s} {text}", flush=True)

    def event(self, text):
        self.out("event", text)

    # ---- MQTT callbacks (paho thread) ------------------------------------------
    def _on_connect(self, c, u, flags, rc, *args):
        if getattr(rc, "value", rc) == 0:
            self.connected.set()

    def _on_disconnect(self, c, u, *args):
        self.lost.set()

    def _on_message(self, c, u, m):
        try:
            text = m.payload.decode("utf-8")
        except UnicodeDecodeError:
            return
        if m.topic == BROKERS_TOPIC:
            before = {x.label for x in self.sel.b}
            k = self.sel.learn(text, self.a.allow_prefix)
            new = sorted({x.label for x in self.sel.b} - before)
            if new:
                self.event(f"learned {','.join(new)} from {BROKERS_TOPIC} ({k} entries)")
            return
        if m.topic == self.t_ack:
            try:
                d = json.loads(text)
            except ValueError:
                return
            if d.get("epoch") != self.epoch:
                return
            with self.lock:
                s = self.slots.get(d.get("seq"))
                if s:
                    s[1] = True
                self.first_unacked_pub = 0.0    # a bridge is alive behind this broker

    # ---- connecting ----------------------------------------------------------------
    def connect_to(self, i):
        br = self.sel.b[i]
        self.conn_count += 1
        self.session = f"{self.epoch}.{self.conn_count}"
        c = make_client(self.dev)
        if self.a.username:
            c.username_pw_set(self.a.username, self.a.password or None)
        c.will_set(self.t_status, json.dumps({"state": "offline", "id": self.dev, "session": self.session}),
                   qos=1, retain=True)
        try:
            c.connect_timeout = self.a.connect_timeout
        except AttributeError:
            c._connect_timeout = self.a.connect_timeout
        c.on_connect, c.on_disconnect, c.on_message = self._on_connect, self._on_disconnect, self._on_message
        self.connected.clear()
        self.lost.clear()
        try:
            c.connect(br.host, br.port, keepalive=self.a.keepalive)
        except OSError as e:
            self.event(f"unreachable {br.label} ({br.host}:{br.port}): {e.__class__.__name__}")
            self.sel.on_failed(i, now_ms())
            return False
        c.loop_start()
        deadline = time.time() + self.a.connect_timeout + 1.0
        while not self.connected.is_set() and not self.lost.is_set() and time.time() < deadline:
            time.sleep(0.02)
        if not self.connected.is_set():
            self.event(f"no CONNACK from {br.label}")
            c.loop_stop()
            try:
                c.socket() and c.socket().close()
            except Exception:
                pass
            self.sel.on_failed(i, now_ms())
            return False
        self.client = c
        self.sel.on_connected(i, now_ms())
        c.subscribe([(BROKERS_TOPIC, 1), (self.t_ack, 1)])
        c.publish(self.t_status, json.dumps({
            "state": "online", "id": self.dev, "session": self.session, "epoch": self.epoch,
            "boot": self.boot, "fw": "sim-2.0.0", "ip": "127.0.0.1",
            "home": self.sel.b[self.sel.home].label, "broker": br.label}), qos=1, retain=True)
        with self.lock:
            self.conn_start_seq = self.seq
            self.first_unacked_pub = 0.0
        self.ack_wait_until = now_ms() + int(self.a.ack_wait * 1000)
        self.resend_cursor = None
        self.event(f"connected {br.label} ({br.host}:{br.port}) session {self.session}")
        return True

    def drop(self):
        c, self.client = self.client, None
        if c:
            c.loop_stop()
            try:
                c.socket() and c.socket().close()
            except Exception:
                pass

    def leave_cleanly(self):
        c, self.client = self.client, None
        if c:
            c.publish(self.t_status, b"", qos=1, retain=True).wait_for_publish(2)
            c.disconnect()
            c.loop_stop()
        self.sel.current = -1

    # ---- readings ----------------------------------------------------------------------
    def make_reading(self):
        el = time.time() - self.start
        cur = self.sel.b[self.sel.current].label if self.sel.current >= 0 else ""
        msg = {"v": 2, "id": self.dev, "epoch": self.epoch, "boot": self.boot, "seq": self.seq,
               "ts": 0 if self.a.no_ntp else int(time.time()), "up_ms": int(el * 1000),
               "rssi": random.randint(-75, -50), "via": cur}
        if self.a.v1:
            msg = {k: v for k, v in msg.items() if k not in ("epoch", "via")}
            msg["v"] = 1
        if not self.a.no_dht:
            msg["temperature"] = round(25 + 1.5 * math.sin(el / 60) + random.uniform(-0.3, 0.3), 1)
            msg["humidity"] = round(57 + 3 * math.cos(el / 90) + random.uniform(-1, 1), 1)
        if not self.a.no_ldr:
            raw = max(0, min(4095, int(1800 + 900 * math.sin(el / 20) + random.randint(-60, 60))))
            msg["light_raw"], msg["light_pct"] = raw, raw * 100 // 4095
        return msg

    def publish_tele(self, payload):
        c = self.client
        if c is None:
            return False
        ok = c.publish(self.t_tele, payload, qos=0).rc == mqtt.MQTT_ERR_SUCCESS
        if ok:
            with self.lock:
                if not self.first_unacked_pub:
                    self.first_unacked_pub = time.time()
        return ok

    def take_reading(self, n):
        msg = self.make_reading()
        payload = json.dumps(msg, separators=(",", ":"))
        kind = "ok"
        a = self.a
        if a.malformed_every and n % a.malformed_every == 0:
            payload, kind = payload[:-7] + "{{oops", "malformed"
        elif a.range_every and n % a.range_every == 0:
            payload, kind = json.dumps(dict(msg, humidity=150.0)), "out-of-range"
        elif a.replay_every and n % a.replay_every == 0 and self.last_payload:
            payload, kind = self.last_payload, "replay"
        if kind == "ok":
            with self.lock:
                self.slots[self.seq] = [payload, False]
                old = self.seq - a.resend_slots
                self.slots.pop(old, None)
                self.seq += 1
            self.last_payload = payload
        sent = self.publish_tele(payload)
        self.out(kind if sent or kind != "ok" else "buffered", payload)

    def resend_some(self):
        if self.client is None or self.resend_cursor is None:
            return
        with self.lock:
            end = self.conn_start_seq
            todo = []
            while self.resend_cursor < end and len(todo) < 8:
                s = self.slots.get(self.resend_cursor)
                if s and not s[1]:
                    todo.append((self.resend_cursor, s[0]))
                self.resend_cursor += 1
            done = self.resend_cursor >= end
        for seq, payload in todo:
            if self.publish_tele(payload):
                self.out("resend", payload)
        if done:
            self.resend_cursor = None

    def probe_home(self):
        h = self.sel.b[self.sel.home]
        try:
            with socket.create_connection((h.host, h.port), timeout=self.a.connect_timeout):
                return True
        except OSError:
            return False

    # ---- main loop -------------------------------------------------------------------------
    def bye(self, *_):
        c = self.client
        if c:
            c.publish(self.t_status, json.dumps({"state": "offline", "id": self.dev, "session": self.session}),
                      qos=1, retain=True)
            time.sleep(0.3)
            c.disconnect()
            c.loop_stop()
        sys.exit(0)

    def run(self):
        signal.signal(signal.SIGTERM, self.bye)
        signal.signal(signal.SIGINT, self.bye)
        finish = threading.Event()
        signal.signal(signal.SIGUSR1, lambda *_: finish.set())
        self.event(f"power-up epoch {self.epoch} boot {self.boot}, {len(self.sel.b)} brokers, "
                   f"home {self.sel.b[self.sel.home].label}")
        n_sent, next_reading, next_attempt = 0, 0.0, 0
        while (self.a.count == 0 or n_sent < self.a.count) and not finish.is_set():
            t = time.time()
            if t >= next_reading:
                next_reading = t + self.a.interval
                n_sent += 1
                self.take_reading(n_sent)
            now = now_ms()
            if self.client is not None and self.lost.is_set():
                self.event(f"lost {self.sel.b[self.sel.current].label}, failing over")
                cur = self.sel.current
                self.drop()
                self.sel.on_failed(cur, now)
            if self.client is None:
                if now >= next_attempt:
                    i = self.sel.next(now)
                    if i >= 0:
                        if not self.connect_to(i):
                            next_attempt = 0
                    else:
                        w = self.sel.wait_ms(now)
                        next_attempt = now + max(250, min(5000, w))
                time.sleep(0.02)
                continue
            if self.ack_wait_until and now >= self.ack_wait_until:
                self.ack_wait_until = 0
                with self.lock:
                    self.resend_cursor = max(0, self.conn_start_seq - self.a.resend_slots)
            self.resend_some()
            with self.lock:
                fu = self.first_unacked_pub
            if fu and time.time() - fu >= self.a.no_ack_failover:
                cur = self.sel.current
                self.event(f"no acks via {self.sel.b[cur].label} for {self.a.no_ack_failover:g}s: "
                           f"its bridge is down, failing over")
                c, self.client = self.client, None
                c.disconnect()          # clean: the next session's online supersedes this one
                c.loop_stop()
                self.sel.penalize(cur, now_ms(), int(3000 * self.a.no_ack_failover))
                next_attempt = 0
                continue
            if self.sel.probe_due(now):
                self.sel.on_home_probe(self.probe_home(), now)
            if self.sel.should_return_home(now):
                self.event(f"home {self.sel.b[self.sel.home].label} stable for {self.a.home_stable:g}s: "
                           f"moving back")
                self.leave_cleanly()
                next_attempt = 0
            time.sleep(0.02)
        # finish: give resends a moment, then a graceful goodbye
        end, last_pass = time.time() + self.a.drain, time.time()
        while time.time() < end:
            if self.client is not None and self.lost.is_set():
                cur = self.sel.current
                self.drop()
                self.sel.on_failed(cur, now_ms())
            if self.client is None:                 # still detached: keep failing over
                i = self.sel.next(now_ms())
                if i >= 0:
                    self.connect_to(i)
                time.sleep(0.05)
                continue
            with self.lock:
                pending = [s for s, v in self.slots.items() if not v[1]]
            if not pending:
                break
            # every ack-wait period, re-send everything still unacknowledged
            if self.resend_cursor is None and time.time() - last_pass >= self.a.ack_wait:
                with self.lock:
                    self.conn_start_seq = self.seq
                    self.resend_cursor = max(0, self.seq - self.a.resend_slots)
                last_pass = time.time()
            self.resend_some()
            time.sleep(0.05)
        with self.lock:
            left = sorted(s for s, v in self.slots.items() if not v[1])
        self.event(f"finished: {self.seq} readings taken, {len(left)} unacknowledged {left[:10]}")
        self.bye()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="esp32-dht-01")
    ap.add_argument("--brokers", default="", help="seed list label=host:port,... (cluster mode)")
    ap.add_argument("--home", default="", help="home broker label (default: the first seed)")
    ap.add_argument("--host", default="127.0.0.1", help="single-broker mode")
    ap.add_argument("--port", type=int, default=1883, help="single-broker mode")
    ap.add_argument("--allow-prefix", default="", help="accept learned hosts only with this prefix")
    ap.add_argument("--state-file", default="", help="NVS stand-in (epoch); default: time-based epoch")
    ap.add_argument("--username", default="")
    ap.add_argument("--password", default="")
    ap.add_argument("--interval", type=float, default=5.0)
    ap.add_argument("--count", type=int, default=0, help="stop after N readings (0 = forever)")
    ap.add_argument("--keepalive", type=int, default=4)
    ap.add_argument("--connect-timeout", type=float, default=1.5)
    ap.add_argument("--backoff-base", type=float, default=1.0)
    ap.add_argument("--backoff-max", type=float, default=60.0)
    ap.add_argument("--home-probe", type=float, default=30.0)
    ap.add_argument("--home-stable", type=float, default=120.0)
    ap.add_argument("--resend-slots", type=int, default=64)
    ap.add_argument("--ack-wait", type=float, default=1.5)
    ap.add_argument("--no-ack-failover", type=float, default=20.0,
                    help="fail over if nothing is acknowledged for this long (bridge down)")
    ap.add_argument("--drain", type=float, default=3.0, help="at --count end, wait this long for acks")
    ap.add_argument("--no-dht", action="store_true")
    ap.add_argument("--no-ldr", action="store_true")
    ap.add_argument("--no-ntp", action="store_true", help="send ts=0 like an ESP32 without NTP")
    ap.add_argument("--v1", action="store_true", help="legacy v1 payloads (boot id, no epoch)")
    ap.add_argument("--malformed-every", type=int, default=0)
    ap.add_argument("--range-every", type=int, default=0)
    ap.add_argument("--replay-every", type=int, default=0)
    ap.add_argument("--quiet", action="store_true")
    Sensor(ap.parse_args()).run()


if __name__ == "__main__":
    main()
