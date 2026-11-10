#!/usr/bin/env bash
# bench_baseline.sh - BASELINE: plain OM2M access latency, NO chain.
# Measures a normal oneM2M RETRIEVE on an UNPROTECTED resource (native ACP only,
# no DAS, no on-chain check). The gap between this and bench_latency_v2 is the
# overhead the blockchain layer adds. Run from laptop. Default node = the DAS node in deploy/inventory.tsv.
set -uo pipefail
INV_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${REPO:-$INV_REPO}"
# shellcheck source=../scripts/lib/inventory.sh
. "$INV_REPO/scripts/lib/inventory.sh"; inv_load   # nodes: deploy/inventory.tsv
NODE="${1:-${INV_IP[$(inv_das)]}}"; N="${2:-30}"; PW="${PW:-user}"; ORIG="${ORIG:-admin:admin}"
BASE=http://127.0.0.1:8282
ssh_n() { ssh -F "$INV_SSH_CONFIG" -i "${SSH_KEY:-$HOME/.ssh/id_ed25519_suiom2m}" -o BatchMode=yes user@"$NODE" "$@"; }   # v8: key auth (password automation removed)

echo "# baseline OM2M RETRIEVE latency (no chain)  node=$NODE  n=$N"
# create a plain unprotected container to read (idempotent; ignore 409)
ssh_n "curl -s -o /dev/null -X POST '$BASE/~/in-cse/in-name' -H 'X-M2M-Origin: $ORIG' -H 'X-M2M-RI: b0' -H 'Content-Type: application/json;ty=3' -d '{\"m2m:cnt\":{\"rn\":\"baseline-cnt\"}}'"
# warm-up x3, then N timed RETRIEVEs; print each time_total in ms
ssh_n "for i in 1 2 3; do curl -s -o /dev/null '$BASE/~/in-cse/in-name/baseline-cnt' -H 'X-M2M-Origin: $ORIG'; done
for i in \$(seq 1 $N); do
  curl -s -o /dev/null -w '%{time_total}\n' '$BASE/~/in-cse/in-name/baseline-cnt' -H 'X-M2M-Origin: $ORIG'
done" | python3 -c '
import sys,statistics as s
v=[float(x)*1000 for x in sys.stdin.read().split() if x.strip()]
if not v: print("no samples"); sys.exit()
print("n=%d mean=%.1f sd=%.1f min=%.1f max=%.1f p50=%.1f ms" % (len(v),s.mean(v),s.stdev(v),min(v),max(v),s.median(v)))
print("-> baseline: %.1f +/- %.1f ms" % (s.mean(v),s.stdev(v)))
'
