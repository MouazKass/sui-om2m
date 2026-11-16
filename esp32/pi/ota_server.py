#!/usr/bin/env python3
"""ota_server.py - read-only firmware server for the ESP32 sensors (fw 2.4).

Serves exactly two kinds of file from ROOT (default /var/lib/om2m-ota):
    GET /fw/manifest.json      the current signed release manifest
    GET /fw/<name>.bin         firmware images named by a manifest
Nothing else: no directory listing, no other paths, no symlinks out of ROOT,
GET/HEAD only, and only to clients in --allow (default: the sensor Wi-Fi
192.168.1.0/24 and localhost). The images carry the Wi-Fi credentials from
config_local.h, so they are not offered on the wired/university network. It needs no trust: the board verifies the manifest signature and
the image SHA-256 itself, so a compromised server (or anyone on the Wi-Fi) can
at worst withhold an update, never install one. Every Pi runs it, so the boards
reach it through the cluster address 192.168.1.250 like the MQTT broker.

    ota_server.py [--root DIR] [--bind 0.0.0.0] [--port 8070] [--allow CIDR,...]
"""
import argparse
import ipaddress
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAME_RE = re.compile(r"^/fw/(manifest\.json|[A-Za-z0-9._-]{1,64}\.bin)$")
MAX_FILE = 4 * 1024 * 1024


class Handler(BaseHTTPRequestHandler):
    server_version = "om2m-ota/1"
    sys_version = ""
    root = "/var/lib/om2m-ota"
    allow = [ipaddress.ip_network("192.168.1.0/24"), ipaddress.ip_network("127.0.0.0/8")]

    def _resolve(self):
        path = self.path.split("?", 1)[0]
        m = NAME_RE.match(path)
        if not m:
            return None
        full = os.path.realpath(os.path.join(self.root, "fw", m.group(1)))
        if os.path.dirname(full) != os.path.realpath(os.path.join(self.root, "fw")):
            return None
        if not os.path.isfile(full) or os.path.getsize(full) > MAX_FILE:
            return None
        return full

    def _allowed(self):
        try:
            ip = ipaddress.ip_address(self.client_address[0])
        except ValueError:
            return False
        if ip.version == 6 and ip.ipv4_mapped:
            ip = ip.ipv4_mapped
        return any(ip in net for net in self.allow)

    def _send(self, head_only):
        if not self._allowed():
            self.send_error(403)
            return
        full = self._resolve()
        if full is None:
            self.send_error(404)
            return
        with open(full, "rb") as f:
            data = f.read()
        self.send_response(200)
        ctype = "application/json" if full.endswith(".json") else "application/octet-stream"
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not head_only:
            self.wfile.write(data)

    def do_GET(self):
        self._send(False)

    def do_HEAD(self):
        self._send(True)

    def log_message(self, fmt, *args):
        sys.stderr.write("[ota] %s %s\n" % (self.address_string(), fmt % args))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.environ.get("OTA_ROOT", "/var/lib/om2m-ota"))
    ap.add_argument("--bind", default=os.environ.get("OTA_BIND", "0.0.0.0"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("OTA_PORT", "8070")))
    ap.add_argument("--allow", default=os.environ.get("OTA_ALLOW", "192.168.1.0/24,127.0.0.0/8"))
    a = ap.parse_args()
    Handler.root = a.root
    Handler.allow = [ipaddress.ip_network(x.strip()) for x in a.allow.split(",") if x.strip()]
    srv = ThreadingHTTPServer((a.bind, a.port), Handler)
    srv.daemon_threads = True
    sys.stderr.write(f"[ota] serving {a.root}/fw on {a.bind}:{a.port}\n")
    srv.serve_forever()


if __name__ == "__main__":
    main()
