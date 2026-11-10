#!/usr/bin/env python3
"""Cross-implementation check: every message the REAL firmware (C++, libsodium)
published in the host build must verify with the bridge's verifier (Python,
cryptography), all under one device key whose Sui address the firmware printed.

    python3 tests/test_fw_signatures.py <fw_pub.txt> [<fw_host.err>]
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "pi"))
import esp_identity as idm  # noqa: E402


def main():
    pub = sys.argv[1]
    keys, n_tele, n_status, bad = set(), 0, 0, []
    for line in open(pub, encoding="utf-8"):
        if not line.startswith("PUB\t"):
            continue
        _, topic, _retained, payload = line.rstrip("\n").split("\t", 3)
        if not payload:                       # cleared retained presence
            continue
        raw = payload.encode()
        try:
            pk = idm.verify_message(raw, json.loads(raw))
        except (idm.IdentityError, ValueError) as e:
            bad.append((topic, str(e), payload[:80]))
            continue
        keys.add(pk)
        if topic.endswith("/telemetry"):
            n_tele += 1
        elif topic.endswith("/status"):
            n_status += 1
    ok = True

    def check(name, cond, detail=""):
        nonlocal ok
        print(f"  [{'PASS' if cond else 'FAIL'}] {name}  {detail}")
        ok = ok and cond

    check("every firmware message verifies in Python", not bad and n_tele > 0,
          f"{n_tele} telemetry + {n_status} status verified, {len(bad)} failed {bad[:2]}")
    check("all signed by one device key", len(keys) == 1, f"{len(keys)} distinct keys")
    if len(sys.argv) > 2 and keys:
        m = re.findall(r"sui_address=(0x[0-9a-f]{64})", open(sys.argv[2], encoding="utf-8").read())
        addr = idm.sui_address(next(iter(keys)))
        check("firmware's printed Sui address == Python's derivation", m and m[0] == addr,
              f"fw {m[0] if m else '-'} py {addr}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
