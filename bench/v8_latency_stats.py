#!/usr/bin/env python3
"""v8_latency_stats.py - summarise bench_v8_dac.sh output.

Reads OUTDIR/latency_requests.csv (+ das_decisions.csv) and writes
OUTDIR/latency_summary.csv with n, http-200 count, mean, sd, min, median, p95,
p99, max per phase (ms, curl time_total on rpi3), plus the DAS-internal time
(build + sign + execute of the PTB, as the plugin logs it) per Sui op.
Percentiles: nearest-rank on the sorted samples.
Usage: python bench/v8_latency_stats.py OUTDIR
"""
import csv, math, os, statistics, sys


def pct(v, p):
    s = sorted(v)
    return s[max(0, math.ceil(p / 100 * len(s)) - 1)]


def row(label, v, ok):
    return [label, len(v), ok, round(statistics.mean(v), 1), round(statistics.stdev(v), 1) if len(v) > 1 else 0,
            round(min(v), 1), round(statistics.median(v), 1), round(pct(v, 95), 1), round(pct(v, 99), 1), round(max(v), 1)]


def main(d):
    ph = {}
    for r in csv.DictReader(open(os.path.join(d, "latency_requests.csv"))):
        ph.setdefault(r["phase"], []).append(r)
    out = [["series", "n", "http_200", "mean_ms", "sd_ms", "min_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms"]]
    for p in ("base_read", "base_write", "dac_read", "dac_write", "dac_read_cached"):
        if p in ph:
            v = [float(x["curl_ms"]) for x in ph[p]]
            out.append(row("e2e:" + p, v, sum(1 for x in ph[p] if x["http"] == "200")))
    dd = os.path.join(d, "das_decisions.csv")
    if os.path.exists(dd):
        rows = [r for r in csv.DictReader(open(dd)) if r["cached"] == "0" and r["das_ms"]]
        for op, name in (("1", "das_internal:read(op1)"), ("2", "das_internal:write(op2)")):
            v = [float(r["das_ms"]) for r in rows if r["op"] == op]
            if v:
                out.append(row(name, v, sum(1 for r in rows if r["op"] == op and r["decision"] == "GRANT")))
    with open(os.path.join(d, "latency_summary.csv"), "w", newline="") as f:
        csv.writer(f).writerows(out)
    for r in out:
        print(",".join(map(str, r)))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "evidence/v8-measurements")
