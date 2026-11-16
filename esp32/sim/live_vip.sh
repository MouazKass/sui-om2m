#!/usr/bin/env bash
# live_vip.sh - live test of the ESP cluster VIP (deploy/vip/) on the REAL
# cluster. Run from the laptop (Git Bash). The simulated ESP32 runs on rpi1
# and is given ONLY the VIP (cluster=192.168.1.250:1883), exactly like a board
# flashed with config_local.h. rpi1 also logs, every ~0.5 s, which Pi answers
# ARP for the VIP.
#
#   esp32/sim/live_vip.sh            all phases
#   PHASES="bridge" esp32/sim/live_vip.sh
#
# Phases (each restores what it changes):
#   base    the VIP sits on the on-chain parent
#   bridge  stop the parent's ESP bridge -> VIP moves to the best healthy
#           non-parent; start it again -> VIP returns to the parent
#   parent  hand the parent role to another node on-chain (the old parent
#           lets its lease lapse, the new one claims with its own key) -> the
#           VIP follows; then hand it back
# At the end the sensor is drained (every reading acked) and the stored
# contentInstances are counted on every CSE (replicated): no reading lost.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/.." && pwd)
. "$REPO/proofs/lib_v8.sh"
VIP=${VIP:-192.168.1.250}
DEV=${DEV:-esp32-dht-01}
SIMHOST=rpi1
PHASES=${PHASES:-"base bridge parent"}
P=${PARENT:-rpi2}; C=${CLAIMER:-rpi3}
W=/home/user/esp32-live
LOG=/tmp/espvip
LOCK="${CHAIN_LOCK:-}"          # on-chain mutex (mkdir lock), optional
LIVE_LOCK="${LIVE_LOCK:-}"      # cluster-disturbance mutex, held for the whole run
# rpi2's CLI pays only with coins, and its coins can be small (its address
# balance is what the plugin spends); a lease call costs ~0.001 SUI.
[ "${GAS_BUDGET_SET:-}" ] || GAS_BUDGET=10000000
ts() { date +%T; }
VIP_FAIL=0
vip_wait() {   # vip_wait <node> <max_s> <text>: report how long until <node> alone holds the VIP
  local r; r=$(wait_holder "$1" "$2")
  echo "$(ts)    $3 after $r s"
  case $r in timeout*) VIP_FAIL=$((VIP_FAIL+1));; esac
}
lock()   { [ -z "$LOCK" ] && return 0; until mkdir "$LOCK" 2>/dev/null; do sleep 5; done; }
unlock() { [ -z "$LOCK" ] && return 0; rmdir "$LOCK" 2>/dev/null || true; }
holder() {   # which Pi holds the VIP right now (asks every node)
  local n h=""
  for n in "${NODES[@]}"; do
    on "$n" "ip -4 -br addr show dev wlan0 | grep -q ' $VIP/'" 2>/dev/null && h="$h $n"
  done
  echo "${h# }"
}
wait_holder() {   # wait_holder <node> <max_s>: seconds until <node> alone holds the VIP
  local want=$1 max=$2 t0=$(date +%s) h
  while :; do
    h=$(holder)
    [ "$h" = "$want" ] && { echo "$(( $(date +%s) - t0 ))"; return 0; }
    [ $(( $(date +%s) - t0 )) -ge "$max" ] && { echo "timeout (holder: ${h:-none})"; return 1; }
    sleep 1
  done
}

if [ -n "$LIVE_LOCK" ]; then
  until mkdir "$LIVE_LOCK" 2>/dev/null; do sleep 10; done
  trap 'rmdir "$LIVE_LOCK" 2>/dev/null' EXIT
fi
# Two simulators with the same device id kick each other off the broker (same
# MQTT client id) and corrupt every count: refuse to start beside one.
if on "$SIMHOST" "pgrep -f '[e]sp32_sim.py --device $DEV ' >/dev/null"; then
  echo "FATAL: a simulator for $DEV is already running on $SIMHOST (another live_vip.sh?)"; exit 1
fi
echo "$(ts) == sync esp32/ to $SIMHOST:$W (config_local.h is never copied)"
tar -C "$HERE" --exclude=__pycache__ --exclude=sim_runtime --exclude=config_local.h --exclude=build -cf - . \
  | on "$SIMHOST" "rm -rf $W && mkdir -p $W && tar -C $W -xf -"
on "$SIMHOST" "cat > $W/pi/ack_keys.txt" < "$REPO/deploy/v9/ack_keys/trusted.txt"

echo "$(ts) == start the VIP watcher and the simulated sensor on $SIMHOST"
# Two small runners on the Pi, started with setsid -f so the ssh call returns at
# once (a plain "nohup ... &" left the remote shell, and so ssh, waiting).
on "$SIMHOST" "rm -rf $LOG; mkdir -p $LOG; cat > $LOG/watch.sh" <<'WATCH'
VIP=$1
while :; do
  if ip -4 -br addr show dev wlan0 | grep -q " $VIP/"; then m=local
  else m=$(sudo arping -c1 -w1 -I wlan0 "$VIP" 2>/dev/null | grep -oE "\[[0-9A-Fa-f:]{17}\]" | head -1); fi
  echo "$(date +%s.%N | cut -c1-14) ${m:--}"; sleep 0.4
done
WATCH
on "$SIMHOST" "cat > $LOG/sim.sh" <<'SIM'
W=$1 DEV=$2 VIP=$3
cd "$W" && exec python3 -u sim/esp32_sim.py --device "$DEV" --key "$HOME/.config/om2m-esp32-sim/$DEV.key" \
  --brokers "cluster=$VIP:1883" --home cluster --allow-prefix "$VIP" \
  --state-file "$HOME/.config/om2m-esp32-sim/$DEV.nvs" --interval 2 --keepalive 4 \
  --backoff-max 2 --no-ack-failover 20 --drain 20 --ack-keys pi/ack_keys.txt
SIM
on "$SIMHOST" "setsid -f bash $LOG/watch.sh $VIP > $LOG/watch.log 2>&1 < /dev/null
  setsid -f bash $LOG/sim.sh $W $DEV $VIP > $LOG/sim.log 2>&1 < /dev/null
  echo started"
sleep 20
EPOCH=$(on "$SIMHOST" "grep -oE 'power-up epoch [0-9]+' $LOG/sim.log | head -1 | grep -oE '[0-9]+$'")
echo "$(ts)    sensor epoch $EPOCH; $(on "$SIMHOST" "grep -E 'connected cluster' $LOG/sim.log | tail -1")"

for ph in $PHASES; do
case $ph in
base)
  echo; echo "$(ts) == base: the VIP is on the parent"
  echo "    parent on-chain: $(on "$P" "sudo python3 -c 'import json;d=json.load(open(\"/var/lib/om2m-ipe-bridge/parent.json\"));print(d[\"label\"],\"epoch\",d[\"epoch\"])'")"
  echo "    VIP holder:      $(holder)"
  sleep 20 ;;
bridge)
  echo; echo "$(ts) == bridge: stop $P's ESP bridge (parent unhealthy for ESP service)"
  on "$P" "sudo systemctl stop om2m-ipe-bridge"; echo "$(ts)    stopped"
  vip_wait rpi1 60 "VIP moved to rpi1 (best healthy non-parent)"
  sleep 30
  on "$P" "sudo systemctl start om2m-ipe-bridge"; echo "$(ts) == bridge: $P's bridge started again"
  vip_wait "$P" 90 "VIP back on $P"
  sleep 30 ;;
parent)
  echo; echo "$(ts) == parent: hand the parent role $P -> $C on-chain"
  lock
  node_call "$P" failover renew_lease "$CLUSTER" 0 0x6; expect "$P renews to 0 ms (lapse)" success
  sleep 3
  node_call "$C" failover claim_parent "$CLUSTER" "$IDENTITY_REG" "$TRUST_REG" 0x6; expect "$C claims" success
  unlock
  vip_wait "$C" 120 "VIP on the new parent $C (bridge chain poll + preempt delay)"
  sleep 40
  echo; echo "$(ts) == parent: hand it back $C -> $P"
  lock
  node_call "$C" failover renew_lease "$CLUSTER" 0 0x6; expect "$C renews to 0 ms (lapse)" success
  sleep 3
  node_call "$P" failover claim_parent "$CLUSTER" "$IDENTITY_REG" "$TRUST_REG" 0x6; expect "$P claims back" success
  unlock
  vip_wait "$P" 120 "VIP back on $P"
  sleep 40 ;;
esac
done

echo; echo "$(ts) == drain the sensor (every reading acked), then count what was stored"
# [e]/[w] keep the patterns from matching this very ssh command line.
on "$SIMHOST" "pkill -USR1 -f '[e]sp32_sim.py --device $DEV '; sleep 25; pkill -f '[e]sp32_sim.py --device $DEV ' ; pkill -f '$LOG/[w]atch.sh' ; true"
on "$SIMHOST" "grep -E 'power-up|connected|lost|unreachable|no CONNACK|no acks|finished' $LOG/sim.log" | sed 's/^/   sim: /'
TAKEN=$(on "$SIMHOST" "grep -oE 'finished: [0-9]+ readings taken, [0-9]+ unack' $LOG/sim.log | tail -1")
N=$(grep -oE '[0-9]+' <<<"$TAKEN" | head -1)
echo "    $TAKEN"
declare -A SEEN=()
TOTAL=0
for n in "${NODES[@]}"; do
  list=$(on "$n" "curl -s -H 'X-M2M-Origin: admin:admin' -H 'Accept: application/json' 'http://127.0.0.1:8282/~/in-cse/in-name/$DEV/data?fu=1&ty=4'" \
         | grep -oE "e$EPOCH-s[0-9]+" | sort -u)
  c=$(grep -c . <<<"$list"); [ -z "$list" ] && c=0
  echo "    stored on $n's CSE: $c reading(s) of epoch $EPOCH"
  for r in $list; do SEEN[$r]=$(( ${SEEN[$r]:-0} + 1 )); done
done
# Since the replication change every reading is meant to be on every CSE, and a
# CSE refuses a second copy of the same e<epoch>-s<seq> (409), so "lost" means
# on NO CSE; per-CSE coverage is reported for information.
missing=0; dup=0; all=0; lost=""
NCSE=${#NODES[@]}
for (( s=0; s<${N:-0}; s++ )); do
  k="e$EPOCH-s$s"; v=${SEEN[$k]:-0}
  [ "$v" -eq 0 ] && { missing=$((missing+1)); lost="$lost $s"; }
  [ "$v" -eq "$NCSE" ] && all=$((all+1))
done
echo "    taken $N, on no CSE (lost) $missing${lost:+ (seq$lost)}, on all $NCSE CSEs $all"
echo
echo "$(ts) == VIP holder timeline (ARP from $SIMHOST; local = $SIMHOST itself)"
on "$SIMHOST" "awk '{ if (\$2 != last) { print \$1, \$2; last = \$2 } }' $LOG/watch.log" | sed 's/^/    /'
echo "    final holder: $(holder)"
[ "$missing" -eq 0 ] && [ "$dup" -eq 0 ] && [ "${PROOF_FAIL:-0}" -eq 0 ] && [ "${VIP_FAIL:-0}" -eq 0 ]   && echo "RESULT: PASS" || echo "RESULT: FAIL (missing $missing, dup $dup, failed steps ${PROOF_FAIL:-0}, VIP timeouts ${VIP_FAIL:-0})"
