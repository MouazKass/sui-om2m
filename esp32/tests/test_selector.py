#!/usr/bin/env python3
"""Runs sim/selector_vectors.txt against the simulator's Selector (the same
vectors cluster_test.cpp runs against the firmware's cluster.h)."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "sim"))
from esp32_sim import Selector, compare_session  # noqa: E402


def run(path):
    s = Selector()
    checks = fails = 0
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = line.split()
        cmd, want, got = f[0], (f[f.index("->") + 1] if "->" in f else None), None
        lbl = lambda i: "none" if i < 0 else s.b[i].label
        if cmd == "params":
            s.base, s.max, s.probe_ms, s.stable_ms = map(int, f[1:5])
        elif cmd == "seeds":
            s.add_seeds(f[1])
        elif cmd == "home":
            s.set_home(f[1])
        elif cmd == "next":
            got = lbl(s.next(int(f[1])))
        elif cmd == "fail":
            s.on_failed(s.find(f[1]), int(f[2]))
        elif cmd == "penalize":
            s.penalize(s.find(f[1]), int(f[2]), int(f[3]))
        elif cmd == "ok":
            s.on_connected(s.find(f[1]), int(f[2]))
        elif cmd == "probe":
            s.on_home_probe(f[1] == "1", int(f[2]))
        elif cmd == "return":
            got = "1" if s.should_return_home(int(f[1])) else "0"
        elif cmd == "wait":
            got = str(s.wait_ms(int(f[1])))
        elif cmd == "learn":
            got = str(s.learn(f[2], "" if f[1] == "-" else f[1]))
        elif cmd == "has":
            got = "1" if s.find(f[1]) >= 0 else "0"
        elif cmd == "alive":
            i = s.find(f[1])
            got = "1" if i >= 0 and s.b[i].alive else "0"
        elif cmd == "session":
            got = str(compare_session(f[1], f[2]))
        else:
            raise SystemExit(f"unknown command line {n}: {line}")
        if want is not None:
            checks += 1
            if got != want:
                fails += 1
                print(f"FAIL line {n}: {line}  (got {got})")
    print(f"esp32_sim Selector vectors: {checks - fails}/{checks} passed")
    return fails


if __name__ == "__main__":
    sys.exit(1 if run(os.path.join(HERE, "..", "sim", "selector_vectors.txt")) else 0)
