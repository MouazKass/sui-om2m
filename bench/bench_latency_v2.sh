#!/usr/bin/env bash
# bench_latency_v2.sh - access-decision latency, PRODUCTION path (the working one).
# Fires N GRANTs with the required X-M2M-Operation:5 header, reads the DAS's own
# elapsedMs from the logs (pure on-chain decision time, no HTTP framing).
# Discards the first (cold-start) sample. Run from laptop. Default node = rpi3.
set -uo pipefail
NODE="${1:-10.25.96.203}"; N="${2:-12}"; PW="${PW:-user}"; ORIG="${ORIG:-admin:admin}"
BASE=http://127.0.0.1:8282
ssh_n() { sshpass -p "$PW" ssh -o StrictHostKeyChecking=no user@$NODE "$@"; }

echo "# native-path access latency  node=$NODE  n=$N (1 cold discarded)"
ssh_n "for i in \$(seq 1 $N); do
  curl -s -o /dev/null -X POST '$BASE/~/in-cse/in-name/sui-das' \
    -H 'X-M2M-Origin: $ORIG' -H \"X-M2M-RI: lat-\$i\" \
    -H 'X-M2M-Operation: 5' -H 'Content-Type: application/json' \
    -d '{\"m2m:sec\":{\"sit\":1,\"dreq\":{\"or\":\"$ORIG\",\"op\":1,\"rid\":\"/in-cse/in-name/sui-protected-cnt\",\"rty\":3}}}'
  sleep 1
done"
echo "=== elapsedMs per GRANT: ==="
ssh_n "docker logs --since $((N*2+10))s om2m-active 2>&1 | grep -oE 'Sui GRANT.*\(([0-9]+) ms\)' | grep -oE '[0-9]+ ms'" \
  | grep -oE '[0-9]+' | python3 -c '
import sys,statistics as s
v=[int(x) for x in sys.stdin.read().split()]
if not v: print("no samples"); sys.exit()
warm=v[1:] if len(v)>1 else v
print("all %d: mean=%.0f sd=%.0f min=%d max=%d" % (len(v),s.mean(v),s.pstdev(v),min(v),max(v)))
if len(warm)>1:
  print("warm %d: mean=%.0f sd=%.0f min=%d max=%d p50=%.0f" % (len(warm),s.mean(warm),s.stdev(warm),min(warm),max(warm),s.median(warm)))
  print("-> report: %.0f +/- %.0f ms (warm, n=%d)" % (s.mean(warm),s.stdev(warm),len(warm)))
'
