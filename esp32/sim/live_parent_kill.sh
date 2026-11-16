#!/usr/bin/env bash
# live_parent_kill.sh - stop the PARENT's CSE container mid-stream and watch every
# node's copy of a device's readings. Run from the LAPTOP (it needs the ssh aliases
# rpi1..rpi5 to stop/start the parent) while a sensor is streaming
# (live_durability.sh start on rpi1, or any simulated sensor).
#
#   esp32/sim/live_parent_kill.sh [device] [outage_s]
#
# Prints every 15 s: readings per CSE and the newest reading name. Afterwards it
# starts the parent again, waits until its copy holds everything the others hold
# (catch-up by backfill/reconcile), then checks the union for gaps and duplicates.
set -euo pipefail
DEV=${1:-esp32-dht-01}; OUT=${2:-90}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
MEM=$REPO/esp32/pi/members.conf
STATE_PY=$(cat <<'EOF'
import json, sys, requests
dev = sys.argv[1]
H = {"X-M2M-Origin": "admin:admin", "Accept": "application/json"}
out = {}
for l in sys.stdin:
    if not l.strip() or l.startswith("#"):
        continue
    lab, url = l.split()[0], l.split()[3]
    try:
        r = requests.get(url + "/~/in-cse/in-name/" + dev + "/data?fu=1&ty=4", headers=H, timeout=4)
        out[lab] = [u.rsplit("/", 1)[-1] for u in r.json().get("m2m:uril", [])] if r.ok else None
    except Exception:
        out[lab] = None
print(json.dumps(out))
EOF
)
state() { ssh rpi1 "python3 -c '$(printf "%s" "$STATE_PY" | sed "s/'/'\\\\''/g")' $DEV" < "$MEM"; }
summ() {
  python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
def key(r):
    e, s = r[1:].split("-s")
    return (int(e), int(s))
parts = []
for k, v in d.items():
    n = "DOWN" if v is None else str(len(v))
    top = max(v, key=key) if v else "-"
    parts.append(k + ":" + n + "/" + top)
print("  ".join(parts))'
}
PARENT=$(ssh rpi1 'sudo cat /var/lib/om2m-ipe-bridge/parent.json' | python3 -c 'import sys,json;print(json.load(sys.stdin)["label"])')
echo "$(date +%T) parent is $PARENT"
echo "$(date +%T) before:  $(state | summ)"
T0=$(date +%s)
ssh "$PARENT" 'docker stop om2m-active >/dev/null' && echo "$(date +%T) t=0 STOPPED $PARENT's CSE container (CSE + plugin)"
trap 'ssh "$PARENT" "docker start om2m-active >/dev/null" || true' EXIT
while (( $(date +%s) - T0 < OUT )); do
  sleep 15
  echo "$(date +%T) t=$(( $(date +%s) - T0 ))  $(state | summ)"
done
ssh "$PARENT" 'docker start om2m-active >/dev/null' && echo "$(date +%T) t=$(( $(date +%s) - T0 )) STARTED $PARENT's CSE container"
trap - EXIT
for i in $(seq 1 40); do
  sleep 15
  S=$(state)
  echo "$(date +%T) t=$(( $(date +%s) - T0 ))  $(echo "$S" | summ)"
  if echo "$S" | python3 -c '
import json, sys
p = sys.argv[1]; d = json.loads(sys.stdin.read())
others = [set(v) for k, v in d.items() if k != p and v is not None]
u = set().union(*others) if others else set()
sys.exit(0 if d.get(p) is not None and u and u <= set(d[p]) else 1)' "$PARENT"; then
    echo "$(date +%T) $PARENT caught up with every reading the others hold"; break
  fi
done
state | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
u = set().union(*[set(v) for v in d.values() if v])
ep = {}
for r in u:
    e, s = r[1:].split("-s")
    ep.setdefault(int(e), set()).add(int(s))
gaps = {}
for e, s in ep.items():
    miss = sorted(set(range(min(s), max(s) + 1)) - s)
    if miss:
        gaps[e] = miss[:8]
dup = {k: len(v) - len(set(v)) for k, v in d.items() if v is not None}
print("union", len(u), "readings; epochs", sorted(ep), "; gaps inside an epoch:", gaps or "none", "; duplicates", dup)
print("complete on:", [k for k, v in d.items() if v is not None and set(v) >= u])'
