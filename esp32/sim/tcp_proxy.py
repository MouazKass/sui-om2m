#!/usr/bin/env python3
"""
tcp_proxy.py - a TCP forwarder that can simulate a network partition.

  python3 tcp_proxy.py --listen 18851 --to 127.0.0.1:18841

The tests put one in front of each simulated Pi's broker and advertise the
proxy as that node's address, exactly as a sensor sees a Pi over WiFi.

  SIGUSR1  partition: keep every socket open but silently drop all bytes in
           both directions (a WiFi/link failure: neither side gets a RST).
  SIGHUP   one-way partition: drop only broker -> sensor bytes. The sensor
           stops getting PINGRESPs and fails over after its keep-alive check,
           while the broker keeps hearing it. While partitioned, a sensor-side
           close reaches the broker only after --linger seconds (a close cannot
           cross a dead link), so the broker fires the sensor's Last Will AFTER
           the sensor is online elsewhere: the late, stale Last Will case.
  SIGUSR2  heal the partition

While the upstream broker is down the proxy stops listening, so a sensor gets
"connection refused", exactly as from a Pi whose Mosquitto has crashed.
"""

import argparse
import signal
import socket
import threading
import time

BLACKHOLE = threading.Event()        # drop both directions
DOWNHOLE = threading.Event()         # drop upstream -> client only
LINGER = [10.0]


def pump(src, dst, downstream=False):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            if not BLACKHOLE.is_set() and not (downstream and DOWNHOLE.is_set()):
                dst.sendall(data)
    except OSError:
        pass
    finally:
        if not downstream and (BLACKHOLE.is_set() or DOWNHOLE.is_set()):
            time.sleep(LINGER[0])          # the close crosses the dead link late
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()


def handle(client, upstream):
    try:
        up = socket.create_connection(upstream, timeout=2)
        up.settimeout(None)
    except OSError:
        client.close()
        return
    threading.Thread(target=pump, args=(client, up), daemon=True).start()
    threading.Thread(target=pump, args=(up, client, True), daemon=True).start()


def upstream_ok(upstream):
    try:
        with socket.create_connection(upstream, timeout=0.3):
            return True
    except OSError:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, required=True)
    ap.add_argument("--to", required=True, help="host:port")
    ap.add_argument("--linger", type=float, default=10.0)
    a = ap.parse_args()
    LINGER[0] = a.linger
    host, port = a.to.rsplit(":", 1)
    upstream = (host, int(port))
    signal.signal(signal.SIGUSR1, lambda *_: BLACKHOLE.set())
    signal.signal(signal.SIGHUP, lambda *_: DOWNHOLE.set())
    signal.signal(signal.SIGUSR2, lambda *_: (BLACKHOLE.clear(), DOWNHOLE.clear()))
    print(f"proxy :{a.listen} -> {a.to}", flush=True)
    srv = None
    while True:
        if srv is None:
            if not upstream_ok(upstream):
                time.sleep(0.2)
                continue
            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(("127.0.0.1", a.listen))
            srv.listen(64)
            srv.settimeout(0.2)
        try:
            c, _ = srv.accept()
            threading.Thread(target=handle, args=(c, upstream), daemon=True).start()
        except socket.timeout:
            if not upstream_ok(upstream):       # broker died: refuse like a real host
                srv.close()
                srv = None


if __name__ == "__main__":
    main()
