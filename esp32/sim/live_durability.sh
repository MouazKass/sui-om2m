#!/usr/bin/env bash
# live_durability.sh - "losing the parent costs zero readings", on the REAL cluster.
# Run ON rpi1 from a copy of esp32/ (the simulated sensor's registered key lives in
# ~/.config/om2m-esp32-sim on rpi1 and never leaves it, see live_identity.sh).
#
#   sim/live_durability.sh start  [device] [interval_s]   sensor with the durable flash buffer
#   sim/live_durability.sh stop   [device]                drain (SIGUSR1) and stop it
#   sim/live_durability.sh kill   [device]                power cut (SIGKILL): only the flash file survives
#   sim/live_durability.sh verify [device]                every ACKED reading: on how many CSEs?
#                                                         union complete per epoch? duplicates?
#   sim/live_durability.sh counts [device]                readings per CSE
#
# The sensor is esp32_sim.py with --flash-buffer (the model of firmware flash_buffer.h):
# a reading is acked by a bridge only once a quorum of CSEs hold it (replicator.py).
set -euo pipefail
CMD=${1:-counts}; DEV=${2:-esp32-dht-01}
cd "$(dirname "$0")/.."
KEYDIR=$HOME/.config/om2m-esp32-sim; install -d -m 700 "$KEYDIR"
KEY=$KEYDIR/$DEV.key
FB=$KEYDIR/$DEV.flash.json
W=/tmp/espdur-$DEV; mkdir -p "$W"
MEM=pi/members.conf
ACKS=pi/ack_keys.txt; ACKARG=(); [[ -f $ACKS ]] && ACKARG=(--ack-keys "$ACKS")
BROKERS=$(awk '!/^#/ && NF>=3 {printf "%s%s=%s:%s", (n++?",":""), $1, $2, $3}' "$MEM")
pidof_sim() { pgrep -f "esp32_sim.py --device $DEV " || true; }
case "$CMD" in
start)
  INTERVAL=${3:-5}
  [[ -n $(pidof_sim) ]] && { echo "already running"; exit 1; }
  nohup python3 -u sim/esp32_sim.py --device "$DEV" --key "$KEY" --brokers "$BROKERS" --home rpi2 \
    --state-file "$KEYDIR/$DEV.nvs" --interval "$INTERVAL" --keepalive 4 --home-probe 10 \
    --home-stable 30 --no-ack-failover 20 --drain 60 --flash-buffer "$FB" "${ACKARG[@]}" \
    >> "$W/sim.log" 2>&1 &
  echo "started pid $! (log $W/sim.log, flash $FB)" ;;
stop)
  p=$(pidof_sim); [[ -z $p ]] && { echo "not running"; exit 0; }
  kill -USR1 $p; for _ in $(seq 1 70); do kill -0 $p 2>/dev/null || break; sleep 1; done
  tail -3 "$W/sim.log" ;;
kill)
  p=$(pidof_sim); [[ -n $p ]] && kill -9 $p && echo "power cut: pid $p killed" || echo "not running" ;;
counts|verify)
  python3 - "$CMD" "$DEV" "$MEM" "$FB" <<'EOF'
import json, sys, requests
cmd, dev, mem, fb = sys.argv[1:5]
H = {"X-M2M-Origin": "admin:admin", "Accept": "application/json"}
nodes = [(l.split()[0], l.split()[3]) for l in open(mem) if l.strip() and not l.startswith("#")]
have = {}
for label, url in nodes:
    try:
        r = requests.get(f"{url}/~/in-cse/in-name/{dev}/data?fu=1&ty=4", headers=H, timeout=10)
        have[label] = [u.rsplit("/", 1)[-1] for u in r.json().get("m2m:uril", [])] if r.ok else None
    except Exception as e:
        have[label] = None
for label, rns in have.items():
    print(f"{label}: {'DOWN/none' if rns is None else len(rns)} readings")
if cmd == "counts":
    sys.exit(0)
sets = {k: set(v) for k, v in have.items() if v is not None}
dups = {k: len(v) - len(set(v)) for k, v in have.items() if v is not None}
try:
    recs = json.load(open(fb))["recs"]
except OSError:
    recs = []
acked = [f"e{r[0]}-s{r[1]}" for r in recs if r[3]]
unacked = [f"e{r[0]}-s{r[1]}" for r in recs if not r[3]]
short = [rn for rn in acked if sum(rn in s for s in sets.values()) < 3]
minh = min((sum(rn in s for s in sets.values()) for rn in acked), default=0)
union = set().union(*sets.values()) if sets else set()
ep = {}
for rn in union:
    e, s = rn[1:].split("-s"); ep.setdefault(int(e), set()).add(int(s))
gaps = {e: sorted(set(range(min(s), max(s) + 1)) - s)[:8] for e, s in ep.items()
        if set(range(min(s), max(s) + 1)) - s}
print(f"sensor flash: {len(acked)} acked, {len(unacked)} unacked {unacked[:5]}")
print(f"acked readings held by >= 3 CSEs: {len(acked) - len(short)}/{len(acked)} (min holders {minh})")
print(f"union: {len(union)} readings; epochs {sorted(ep)}; gaps inside an epoch: {gaps or 'none'}")
print(f"duplicates per CSE: {dups}")
complete = {k: (sets[k] >= union) for k in sets}
print(f"CSEs holding the whole union: {[k for k, v in complete.items() if v]}")
EOF
  ;;
*) sed -n '2,13p' "$0"; exit 1 ;;
esac
