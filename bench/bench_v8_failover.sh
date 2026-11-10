#!/usr/bin/env bash
# bench_v8_failover.sh - one real failover run on the live v8 cluster:
# stop the current parent's CSE container, let the followers detect the silence
# and take over through their own plugins (no human claim), then restart the
# old parent and check it rejoins as a follower.
#
# Records (OUTDIR/failover_<stamp>.csv: event,utc_ms,node,detail):
#   stop            parent container stopped (chain lease remaining at that moment)
#   chain_parent    first chain read naming a new parent (+ epoch)
#   chain_anchor    first chain read with the new parent's anchored lease (> claim's 60 s)
#   log:*           follower plugin log lines since the stop (silence detection,
#                   claim gate, claims accepted/rejected, anchors, PoA)
#   rejoin          old parent restarted and following the new parent
# Disruptive by design; leaves the cluster healthy (verify afterwards with
# scripts/v8/04_cutover.sh verify).
#
# Usage: bench/bench_v8_failover.sh [OUTDIR]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$REPO/evidence/v8-measurements}"; mkdir -p "$OUT"
source "$REPO/deploy/v8/env.v8.sh"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_suiom2m}"
. "$REPO/scripts/lib/inventory.sh"; inv_load   # nodes: deploy/inventory.tsv
mapfile -t NODES < <(inv_nodes active)
declare -A IP=() NAME=()
for _n in "${NODES[@]}"; do IP[$_n]=${INV_IP[$_n]}; NAME[${INV_ADDR[$_n]}]=$_n; done
on() { ssh -F "$INV_SSH_CONFIG" -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "user@${IP[$1]}" "${@:2}"; }
now_ms() { python -c 'import time;print(int(time.time()*1000))'; }
cluster() {  # -> "parent lease_expires_ms epoch"
  python - "$CLUSTER" <<'EOF'
import json,sys,urllib.request,time
q='{ object(address:"%s"){ asMoveObject{ contents{ json } } } }' % sys.argv[1]
for a in range(5):
    try:
        r=urllib.request.Request("https://graphql.testnet.sui.io/graphql",data=json.dumps({"query":q}).encode(),headers={"Content-Type":"application/json"})
        j=json.loads(urllib.request.urlopen(r,timeout=15).read())["data"]["object"]["asMoveObject"]["contents"]["json"]
        print(j["current_parent"].lower(), j["lease_expires_ms"], j["epoch"]); break
    except Exception:
        time.sleep(2)
EOF
}
STAMP=$(date -u +%Y%m%dT%H%M%SZ); CSV="$OUT/failover_$STAMP.csv"
echo "event,utc_ms,node,detail" > "$CSV"
ev() { echo "$1,$2,$3,\"$4\"" >> "$CSV"; echo "  $1 $(date -u -d @$(( $2 / 1000 )) +%T 2>/dev/null || echo $2) $3 $4"; }

read -r P0 LE0 E0 < <(cluster); P=${NAME[$P0]}
echo "# failover run $STAMP: parent=$P epoch=$E0"
T_STOP=$(now_ms)
on "$P" 'docker stop om2m-active >/dev/null'
ev stop "$T_STOP" "$P" "lease remaining $(( (LE0 - T_STOP) / 1000 )) s; epoch $E0"
STOP_UTC=$(date -u -d @$(( T_STOP / 1000 )) +%FT%TZ)

# Wait for the takeover (lease <= MAX 1 h; the plugins anchor 20 min leases).
DEADLINE=$(( T_STOP + 75 * 60 * 1000 ))
while :; do
  read -r PN LEN EN < <(cluster)
  [ -n "${PN:-}" ] && [ "$PN" != "$P0" ] && { ev chain_parent "$(now_ms)" "${NAME[$PN]}" "epoch $E0 -> $EN; lease_expires_ms $LEN"; break; }
  [ "$(now_ms)" -gt "$DEADLINE" ] && { ev timeout "$(now_ms)" "-" "no takeover"; exit 1; }
  sleep 5
done
NEW=${NAME[$PN]}
while :; do
  read -r PN2 LEN2 EN2 < <(cluster)
  [ "$LEN2" -gt $(( $(now_ms) + 120000 )) ] && { ev chain_anchor "$(now_ms)" "$NEW" "lease_expires_ms $LEN2"; break; }
  [ "$(now_ms)" -gt "$DEADLINE" ] && { ev timeout "$(now_ms)" "$NEW" "no anchor"; break; }
  sleep 5
done
sleep 20
for n in "${NODES[@]}"; do
  [ "$n" = "$P" ] && continue
  on "$n" "docker logs --timestamps --since $STOP_UTC om2m-active 2>&1" | python -c '
import sys,re,datetime
node=sys.argv[1]
pat=re.compile(r"(Parent silence detected.*|CLAIM ACCEPTED.*|Claim rejected on-chain.*|Lease anchored.*|PoA published.*|New parent PoA.*|Parent PoA changed.*|Cluster current parent.*|Chain names this node parent.*|Rebuilding transaction.*)")
for l in sys.stdin:
    m=pat.search(l)
    if not m: continue
    ts=l.split(" ",1)[0]
    try: t=int(datetime.datetime.fromisoformat(ts.rstrip("Z")[:26]).replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
    except Exception: continue
    d=m.group(1).replace("\"","'"'"'")[:220]
    print("log:%s,%d,%s,\"%s\"" % (d.split(" ")[0].split(":")[0], t, node, d))
' "$n" >> "$CSV"
done
echo "# restarting the old parent ($P)"
T_RS=$(now_ms); on "$P" 'docker start om2m-active >/dev/null'; ev restart "$T_RS" "$P" "docker start"
for i in $(seq 1 60); do
  L=$(on "$P" "docker logs --since 5m om2m-active 2>&1 | grep -E 'Failover manager started' | tail -1" || true)
  [ -n "$L" ] && { ev rejoin "$(now_ms)" "$P" "$(grep -oE 'parent=0x[0-9a-f]{8}' <<<"$L")"; break; }
  sleep 5
done
echo "# provisioning DAS/DAC on the restarted node"
on "$P" 'for i in $(seq 1 60); do c=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8282/~/in-cse -H "X-M2M-Origin: admin:admin"); [ "$c" = 200 ] && break; sleep 5; done; /usr/local/bin/provision-das.sh 2>&1 | tail -1'
echo "# events -> $CSV"
