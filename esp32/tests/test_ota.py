#!/usr/bin/env python3
"""test_ota.py - signed over-the-air updates (fw 2.4): manifest format, the
boards' acceptance logic, the read-only server and the full fetch-and-verify
path a board (or the simulator) runs.

    python3 tests/test_ota.py [ota_vectors.txt]

argv[1]: manifests signed by the FIRMWARE code (sim/firmware_hostcheck/ota_test.cpp,
libsodium); they must verify with this Python reference, byte for byte.
"""
import hashlib
import os
import socket
import sys
import tempfile
import threading
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "pi"))
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402
import ota_manifest as om  # noqa: E402
import ota_server  # noqa: E402

PASS = FAIL = 0


def check(name, ok, detail=""):
    global PASS, FAIL
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{'  -- ' + detail if detail and not ok else ''}")
    if ok:
        PASS += 1
    else:
        FAIL += 1


def reason(fn, *a):
    try:
        fn(*a)
        return "ok"
    except om.OtaError as e:
        return str(e)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def main():
    rel = Ed25519PrivateKey.from_private_bytes(bytes([0x42]) * 32)
    rogue = Ed25519PrivateKey.generate()
    pk = lambda k: k.public_key().public_bytes_raw().hex()  # noqa: E731
    pinned = {pk(rel)}
    image = bytes((i * 7) & 0xFF for i in range(50_000))
    image = b"\xe9" + image[1:]
    sha = hashlib.sha256(image).hexdigest()

    def manifest(v=240, size=len(image), digest=sha, path="/fw/fw-240.bin", key=rel,
                 target="all", claim=None):
        body = om.body_json(v, size, digest, path, claim or pk(key), target, 1763300000)
        return om.sign_manifest(body, key).encode()

    print("manifest signature and format")
    m = om.verify_manifest(manifest(), pinned)
    check("genuine manifest verifies", m["version"] == 240 and m["sha256"] == sha)
    check("forged (unpinned key)", reason(om.verify_manifest, manifest(key=rogue), pinned) == "untrusted_key")
    check("forged (claims the pinned key)",
          reason(om.verify_manifest, manifest(key=rogue, claim=pk(rel)), pinned) == "bad_signature")
    t = manifest().replace(b'"size":%d' % len(image), b'"size":%d' % (len(image) + 1))
    check("tampered after signing", reason(om.verify_manifest, t, pinned) == "bad_signature")
    body = om.body_json(240, len(image), sha, "/fw/a.bin", pk(rel))
    dev_sig = rel.sign(b"om2m-esp32-sig-v1\x00" + body.encode()).hex()
    check("device-domain signature is not a release",
          reason(om.verify_manifest, (body[:-1] + ',"sig":"' + dev_sig + '"}').encode(), pinned) == "bad_signature")
    dup = body[:-1] + ',"version":999}'
    check("duplicate field refused", reason(om.verify_manifest, om.sign_manifest(dup, rel).encode(), pinned)
          in ("duplicate_field", "bad_fields"))
    check("unsigned refused", reason(om.verify_manifest, body.encode(), pinned) == "unsigned")

    print("acceptance decision (anti-rollback, target, size, path)")
    d = lambda raw, inst=0, bad=0, dev="esp32-dht-01": reason(  # noqa: E731
        om.decide, om.verify_manifest(raw, pinned), dev, inst, bad)
    check("newer release accepted", d(manifest()) == "ok")
    check("same version refused", d(manifest(), inst=240) == "not_newer")
    check("older version refused (rollback attack)", d(manifest(v=239), inst=240) == "not_newer")
    check("failed version not retried", d(manifest(v=241), inst=240, bad=241) == "failed_before")
    check("other device's release refused", d(manifest(target="esp32-dht-02")) == "not_for_this_device")
    check("this device's release accepted", d(manifest(target="esp32-dht-01")) == "ok")
    check("oversized image refused", d(manifest(size=om.SLOT_SIZE + 1)) == "bad_size")
    check("path traversal refused", d(manifest(path="/fw/../etc.bin")) == "bad_path")

    print("C++ (firmware) signed manifests verify in Python")
    if len(sys.argv) > 1 and os.path.exists(sys.argv[1]):
        lines = [ln.split(" ", 1) for ln in open(sys.argv[1]).read().splitlines() if ln.strip()]
        ok = all(om.verify_manifest(raw.encode(), {k}) for k, raw in lines)
        check(f"{len(lines)} firmware-signed manifest(s) verify", ok and len(lines) >= 2)
    else:
        check("vectors file present (run ota_test first)", False, str(sys.argv[1:]))

    print("read-only server + full board path")
    root = tempfile.mkdtemp()
    os.makedirs(os.path.join(root, "fw"))
    with open(os.path.join(root, "secret.txt"), "w") as f:
        f.write("x")
    with open(os.path.join(root, "fw", "fw-240.bin"), "wb") as f:
        f.write(image)
    with open(os.path.join(root, "fw", "manifest.json"), "wb") as f:
        f.write(manifest())
    os.symlink(os.path.join(root, "secret.txt"), os.path.join(root, "fw", "link.bin"))
    port = free_port()
    ota_server.Handler.root = root
    srv = ota_server.ThreadingHTTPServer(("127.0.0.1", port), ota_server.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    def code(path):
        try:
            return urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=3).status
        except urllib.error.HTTPError as e:
            return e.code
    check("serves the manifest", code("/fw/manifest.json") == 200)
    check("serves the image", code("/fw/fw-240.bin") == 200)
    check("no listing", code("/fw/") == 404 and code("/") == 404)
    check("nothing outside /fw", code("/secret.txt") == 404 and code("/fw/../secret.txt") == 404)
    check("symlink out of the release dir refused", code("/fw/link.bin") == 404)
    m = om.check_release("127.0.0.1", port, "esp32-dht-01", 0, pinned)
    check("board path: genuine release accepted", m["version"] == 240)
    check("board path: already installed -> refused",
          reason(om.check_release, "127.0.0.1", port, "esp32-dht-01", 240, pinned) == "not_newer")
    with open(os.path.join(root, "fw", "fw-240.bin"), "r+b") as f:
        f.seek(1000)
        f.write(b"\x00\x01")
    check("board path: tampered image refused",
          reason(om.check_release, "127.0.0.1", port, "esp32-dht-01", 0, pinned) == "sha256_mismatch")
    with open(os.path.join(root, "fw", "fw-240.bin"), "wb") as f:
        f.write(image[:-10])
    check("board path: truncated image refused",
          reason(om.check_release, "127.0.0.1", port, "esp32-dht-01", 0, pinned) == "size_mismatch")
    with open(os.path.join(root, "fw", "manifest.json"), "wb") as f:
        f.write(manifest(key=rogue))
    check("board path: forged manifest refused",
          reason(om.check_release, "127.0.0.1", port, "esp32-dht-01", 0, pinned) == "untrusted_key")
    saved = ota_server.Handler.allow
    ota_server.Handler.allow = [ota_server.ipaddress.ip_network("192.168.1.0/24")]
    check("clients outside the sensor Wi-Fi get 403 (images hold Wi-Fi creds)", code("/fw/manifest.json") == 403)
    ota_server.Handler.allow = saved
    srv.shutdown()

    print(f"OTA: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
