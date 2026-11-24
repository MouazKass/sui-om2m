#!/usr/bin/env python3
"""Flash a NEW board in small hash-verified pieces, retrying each piece.

For a board whose USB-serial link drops partway through a long write
("The chip stopped responding" at a different point each try). Each piece is a
separate esptool call, so a drop costs one 64 KB piece, not the whole image:
bootloader 0x1000, partition table 0x8000, a blank otadata 0xe000 (boot app0),
then the app from 0x10000.

Hold the board's BOOT button for the whole run (on 30-pin boards GPIO0 is not on
the header), so the automatic reset before every piece lands in download mode.

It writes the bootloader and partition table, so it is for a board's FIRST flash.
It does not touch NVS, but a board that already has a registered device key
should get only the app (esptool write_flash 0x10000 <app.bin>). Boards whose MAC
is passed with --known-mac are never written.

  python3 flash_chunked.py --port COM3 --expect-mac 30:76:f5:30:1b:04 \
      --known-mac 20:50:0d:1b:95:6c --build-dir build
"""
import argparse, os, re, subprocess, sys, tempfile

ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
ap.add_argument("--port", required=True)
ap.add_argument("--build-dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "build"))
ap.add_argument("--name", default="esp32_sensor_node.ino", help="build file prefix")
ap.add_argument("--known-mac", action="append", default=[], help="never write this board (repeatable)")
ap.add_argument("--expect-mac", help="write only if the board has this MAC")
ap.add_argument("--baud", default="115200")
ap.add_argument("--chunk-kb", type=int, default=64)
ap.add_argument("--tries", type=int, default=6)
a = ap.parse_args()

def rd(suffix):
    return open(os.path.join(a.build_dir, f"{a.name}.{suffix}"), "rb").read()

chunk = a.chunk_kb * 1024
pieces = [(0x1000, rd("bootloader.bin")), (0x8000, rd("partitions.bin")), (0xE000, b"\xff" * 0x2000)]
app = rd("bin")
pieces += [(0x10000 + i, app[i:i + chunk]) for i in range(0, len(app), chunk)]
known = {m.lower() for m in a.known_mac}
expect = a.expect_mac.lower() if a.expect_mac else None

tmp = tempfile.mkdtemp()
for n, (addr, data) in enumerate(pieces, 1):
    f = os.path.join(tmp, f"p{n}.bin")
    with open(f, "wb") as fh:
        fh.write(data)
    for t in range(1, a.tries + 1):
        r = subprocess.run([sys.executable, "-m", "esptool", "--chip", "esp32", "--port", a.port,
                            "--baud", a.baud, "--before", "default_reset", "--after", "no_reset",
                            "--connect-attempts", "10", "write_flash", "--flash_size", "4MB",
                            hex(addr), f], capture_output=True, text=True, encoding="utf-8",
                           errors="replace")
        o = r.stdout + r.stderr
        m = re.search(r"MAC: ([0-9a-f:]{17})", o)
        mac = m.group(1) if m else None
        if mac and (mac in known or (expect and mac != expect)):
            sys.exit(f"STOP: board MAC {mac} is not the board to flash; nothing more written")
        if "Hash of data verified" in o:
            print(f"[{n}/{len(pieces)}] 0x{addr:06x} {len(data):6d} B ok (try {t})", flush=True)
            break
        last = ([l for l in o.splitlines() if l.strip()] or ["?"])[-1]
        print(f"[{n}/{len(pieces)}] 0x{addr:06x} try {t} failed: {last[:120]}", flush=True)
    else:
        sys.exit(f"GAVE UP at 0x{addr:06x} after {a.tries} tries")

print("ALL PIECES WRITTEN AND VERIFIED - release BOOT, then reset (EN)")
