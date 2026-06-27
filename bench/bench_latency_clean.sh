#!/usr/bin/env bash
# Clean latency: fires until exactly TARGET successful GRANT samples are collected.
# Reads elapsedMs from logs with a wide window. Reports a real round-number n.
set -uo pipefail
NODE="${1:-10.25.96.203}"; TARGET="${2:-100}"; PW="${PW:-user}"; ORIG="${ORIG:-admin:admin}"
BASE=http://127.0.0.1:8282
ssh_n() { sshpass -p "$PW" ssh -o StrictHostKeyChecking=no user@"$NODE" "$@"; }

echo "# clean latency: collecting $TARGET GRANT samples  node=$NODE"
# fire TARGET+15 requests (buffer for any that don't log), 1.2s apart so each logs
FIRE=$((TARGET + 15))
ssh_n "for i in \$(seq 1 $FIRE); do
  curl -s -o /dev/null -X POST '$BASE/~/in-cse/in-name/sui-das' \
    -H 'X-M2M-Origin: $ORIG' -H \"X-M2M-RI: cl-\$i\" \
    -H 'X-M2M-Operation: 5' -H 'Content-Type: application/json' \
    -d '{\"m2m:sec\":{\"sit\":1,\"dreq\":{\"or\":\"$ORIG\",\"op\":1,\"rid\":\"/in-cse/in-name/sui-protected-cnt\",\"rty\":3}}}'
  sleep 1.2
done"
# pull a wide window of logs, take exactly TARGET samples (drop the cold first)
WIN=$((FIRE * 2 + 30))
ssh_n "docker logs --since ${WIN}s om2m-active 2>&1 | grep -oE 'Sui GRANT.*\(([0-9]+) ms\)' | grep -oE '[0-9]+ ms'" \
  | grep -oE '[0-9]+' | python3 -c "
import sys,statistics as s
v=[int(x) for x in sys.stdin.read().split()]
v=v[1:]                      # drop cold-start
T=$TARGET
if len(v)<T:
    print(f'only collected {len(v)} (<{T}); re-run or raise buffer'); sys.exit()
v=v[:T]                      # exactly TARGET
print(f'n={len(v)}  mean={s.mean(v):.0f}  sd={s.stdev(v):.0f}  min={min(v)}  max={max(v)}  p50={s.median(v):.0f}  p95={sorted(v)[int(0.95*len(v))]:.0f}')
print(f'-> report: {s.mean(v):.0f} +/- {s.stdev(v):.0f} ms (n={T})')
"
