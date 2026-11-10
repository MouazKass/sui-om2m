#!/usr/bin/env bash
# bench_v8_dac.sh - end-to-end latency of ORDINARY oneM2M requests on the real
# v8 path (static ACP grants nothing -> DynamicAuthorizationConsultation -> Sui
# DAS -> one 5-command PTB), reads and writes separately, against a no-chain
# baseline on the same CSE.
#
# Measured on rpi3 itself (curl to 127.0.0.1:8282), so no laptop<->Pi RTT is
# included. Every sample is a full HTTP request/response as a oneM2M client sees
# it (curl time_total).
#
# Phases (all on rpi3, originator / resource / oneM2M op):
#   base_read   admin:admin  RETRIEVE /in-cse/in-name/bench-base-cnt  static ACP, no DAS
#   base_write  admin:admin  UPDATE   /in-cse/in-name/bench-base-cnt  (lbl)  static ACP, no DAS
#   dac_read    Csensor-001  RETRIEVE /in-cse/in-name/sui-dac-ae      -> Sui GRANT (op READ)
#   dac_write   Csensor-001  UPDATE   /in-cse/in-name/sui-dac-ae (lbl) -> Sui GRANT (op WRITE)
#   dac_read_cached          as dac_read, back-to-back inside the DAS GRANT
#                            cache TTL (sui.das.cache.ttl.ms=5000): no chain call
# dac_read / dac_write alternate with GAP_S between requests, so the same
# (originator, resource, op) key repeats every 2*GAP_S > the 5 s cache TTL:
# every dac_* sample is a real on-chain transaction (checked: one Sui GRANT
# digest per sample, see das_decisions.csv).
#
# Usage: bench/bench_v8_dac.sh [N] [OUTDIR]     (N per phase, default 100)
# Output: OUTDIR/latency_requests.csv  (phase,i,utc_ms,http,curl_ms)
#         OUTDIR/das_decisions.csv     (utc,decision,op,digest,das_ms) from the plugin log
set -euo pipefail
N="${1:-100}"
OUT="${2:-$(cd "$(dirname "$0")/.." && pwd)/evidence/v8-measurements}"
GAP_S="${GAP_S:-3}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_suiom2m}"
NODE="${NODE:-10.25.96.203}"
mkdir -p "$OUT"
on() { ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "user@$NODE" "$@"; }

START_UTC=$(on 'date -u +%FT%TZ')
echo "# bench_v8_dac  node=$NODE  N=$N  gap=${GAP_S}s  start=$START_UTC"
on "N=$N GAP_S=$GAP_S bash -s" > "$OUT/latency_requests.csv" <<'REMOTE'
set -uo pipefail
B=http://127.0.0.1:8282/~/in-cse/in-name
J='Accept: application/json'
ms() { date +%s%3N; }
req() {  # phase i curl-args...
  local p=$1 i=$2 t r; shift 2; t=$(ms)
  r=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' "$@")
  echo "$p,$i,$t,${r% *},$(awk -v s="${r#* }" 'BEGIN{printf "%.1f", s*1000}')"
}
echo "phase,i,utc_ms,http,curl_ms"
# baseline resource: unprotected-by-chain container, static ACP admin:admin only
curl -s -o /dev/null -X POST "$B" -H 'X-M2M-Origin: admin:admin' -H 'Content-Type: application/json;ty=3' \
  -d '{"m2m:cnt":{"rn":"bench-base-cnt"}}'
for w in 1 2 3; do curl -s -o /dev/null "$B/bench-base-cnt" -H 'X-M2M-Origin: admin:admin'; done
for i in $(seq 1 "$N"); do req base_read "$i" "$B/bench-base-cnt" -H 'X-M2M-Origin: admin:admin' -H "$J"; sleep 0.2; done
for i in $(seq 1 "$N"); do req base_write "$i" -X PUT "$B/bench-base-cnt" -H 'X-M2M-Origin: admin:admin' -H 'Content-Type: application/json' -H "$J" -d "{\"m2m:cnt\":{\"lbl\":[\"b$i\"]}}"; sleep 0.2; done
sleep 6
for i in $(seq 1 "$N"); do
  req dac_read "$i" "$B/sui-dac-ae" -H 'X-M2M-Origin: Csensor-001' -H "$J"; sleep "$GAP_S"
  req dac_write "$i" -X PUT "$B/sui-dac-ae" -H 'X-M2M-Origin: Csensor-001' -H 'Content-Type: application/json' -H "$J" -d "{\"m2m:ae\":{\"lbl\":[\"w$i\"]}}"; sleep "$GAP_S"
done
sleep 6
curl -s -o /dev/null "$B/sui-dac-ae" -H 'X-M2M-Origin: Csensor-001'   # warm the cache entry (on-chain)
for i in $(seq 1 "$N"); do req dac_read_cached "$i" "$B/sui-dac-ae" -H 'X-M2M-Origin: Csensor-001' -H "$J"; done
REMOTE
echo "# requests done: $(($(wc -l < "$OUT/latency_requests.csv")-1)) samples"
on "docker logs --since $START_UTC om2m-active 2>&1 | grep -E 'Sui GRANT|Sui DENY'" | python -c '
import sys,re
print("decision,op,digest,das_ms,cached")
for l in sys.stdin:
    m=re.search(r"Sui (GRANT|DENY)( \(cached\))? .*?op=(\d+)(?: digest=(\w+))?(?:.*?\((\d+) ms\))?", l)
    if m: print(",".join([m.group(1), m.group(3), m.group(4) or "", m.group(5) or "", "1" if m.group(2) else "0"]))
' > "$OUT/das_decisions.csv"
echo "# DAS decisions logged: $(($(wc -l < "$OUT/das_decisions.csv")-1))"
