#!/usr/bin/env bash
# live_failover.sh - broker failover of one simulated ESP32 on the REAL cluster.
# Run ON a Pi (rpi1) from esp32/: sudo for the firewall rule and for setpriv (uid switch).
#
#   sim/live_failover.sh [device] [home] [down_s]      (passwordless sudo: rule + setpriv)
#   sim/live_failover.sh esp32-dht-01 rpi2 60
#
# The simulator runs under an otherwise unused uid (SIM_UID, default 64999) via
# setpriv, and the one temporary rule matches ONLY that uid and the home
# broker's :1883 (iptables -m owner). Nothing else on the Pi - OM2M, the
# bridges, the broker mesh, gossip, SSH - is affected. The rule is removed on
# exit, even on Ctrl-C (trap).
#
# Timeline: attach home -> home "dies" (DROP, as a powered-off Pi) for down_s ->
# home back -> return home after --home-stable -> drain (every reading acked) ->
# check the stored contentInstances on the parent: no loss, no duplicates.
set -euo pipefail
DEV=${1:-esp32-dht-01}; HOME_N=${2:-rpi2}; DOWN=${3:-60}
SIM_UID=${SIM_UID:-64999}; STABLE=${STABLE:-30}; PRE=${PRE:-30}
cd "$(dirname "$0")/.."
MEM=pi/members.conf
BROKERS=$(awk '!/^#/ && NF>=3 {printf "%s%s=%s:%s", (n++?",":""), $1, $2, $3}' "$MEM")
HOME_IP=$(awk -v h="$HOME_N" '$1==h {print $2}' "$MEM")
[[ -n "$HOME_IP" ]] || { echo "no $HOME_N in $MEM"; exit 1; }
W=/tmp/espsim; rm -rf "$W"; mkdir -p "$W"; chmod 777 "$W"
RULE=(OUTPUT -p tcp -d "$HOME_IP" --dport 1883 -m owner --uid-owner "$SIM_UID" -j DROP)
cleanup() { sudo iptables -D "${RULE[@]}" 2>/dev/null && echo "$(date +%T) rule removed (cleanup)" || true
            [[ -n "${SIM:-}" ]] && sudo -n kill "$SIM" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
ts() { date +%T; }

echo "$(ts) brokers $BROKERS; home $HOME_N ($HOME_IP); sim uid $SIM_UID"
sudo -n setpriv --reuid="$SIM_UID" --regid="$SIM_UID" --clear-groups \
  python3 -u sim/esp32_sim.py --device "$DEV" --brokers "$BROKERS" --home "$HOME_N" \
    --state-file "$W/nvs" --interval 2 --keepalive 4 --home-probe 10 --home-stable "$STABLE" \
    --no-ack-failover 20 --drain 15 > "$W/sim.log" 2>&1 &
SIM=$!
sleep "$PRE"
pgrep -f "esp32_sim.py --device $DEV" >/dev/null || { echo "simulator is not running:"; cat "$W/sim.log"; exit 1; }
echo "$(ts) home broker $HOME_N goes dark for this uid only"
sudo iptables -I "${RULE[@]}"
sudo iptables -S OUTPUT | grep -- "--uid-owner $SIM_UID" | sed 's/^/   rule: /'
sleep "$DOWN"
sudo iptables -D "${RULE[@]}"; echo "$(ts) rule removed: $HOME_N reachable again"
sleep $(( STABLE + 30 ))
echo "$(ts) SIGUSR1: stop readings, drain until every reading is acked"
sudo -n kill -USR1 "$SIM"; wait "$SIM" || true; SIM=
echo "$(ts) simulator exited"
grep -E -i "attach|connect|failover|home|switch|detach|drain|sent|ack" "$W/sim.log" | grep -v -i "telemetry seq" | tail -40 | sed 's/^/   sim: /'
cp "$W/sim.log" "$W/sim.log.keep" 2>/dev/null || true
