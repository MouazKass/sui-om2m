#!/usr/bin/env bash
# install_vip.sh - install/refresh the ESP cluster VIP (keepalived) on every
# active node in deploy/inventory.tsv. Re-run after adding a node: every node's
# unicast peer list is regenerated.
#
#   deploy/vip/install_vip.sh                 # all active nodes
#   ONLY=rpi5 deploy/vip/install_vip.sh       # one node (its peers still come from the inventory)
#   VIP=192.168.1.250 VRID=51 ...             # defaults shown
#
# The VIP sits on the on-chain parent (is_parent.sh reads the ESP bridge's
# parent.json) and falls back to the highest-priority healthy node.
#
# Prereq on each Pi: wlan0 joined to the router's Wi-Fi (NetworkManager profile
# with ipv4.never-default yes, so routing stays on eth0). See ROLLOUT_V9.md "ESP VIP".
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd); cd "$REPO"
. scripts/lib/inventory.sh
inv_load
VIP=${VIP:-192.168.1.250}
VRID=${VRID:-51}
DIR=deploy/vip
nodes=($(inv_nodes active))
# Base priorities 150, 140, ...: all within 100 of each other, so the parent's
# is_parent weight (+100) always outranks every other node.
(( ${#nodes[@]} <= 10 )) || { echo "base priorities 150..60 support at most 10 nodes"; exit 1; }
range="$((150 - 10 * (${#nodes[@]} - 1)))-150"
prio=150
for n in "${nodes[@]}"; do
  p=$prio; prio=$((prio-10))
  [ -n "${ONLY:-}" ] && [ "$ONLY" != "$n" ] && continue
  peers=$(for m in $(inv_peers_of "$n"); do echo "        ${INV_IP[$m]}"; done)
  conf=$(sed -e "s|@NODE@|$n|; s|@VRID@|$VRID|; s|@PRIO@|$p|; s|@SELF_IP@|${INV_IP[$n]}|; s|@VIP@|$VIP|g; s|@PRIO_RANGE@|$range|" "$DIR/keepalived.conf.tmpl" \
         | awk -v peers="$peers" '{ if ($0 == "@PEERS@") print peers; else print }')
  echo "== $n (priority $p)"
  ssh -F "$INV_SSH_CONFIG" "$n" 'command -v keepalived >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq keepalived >/dev/null'
  for s in esp_ready.sh is_parent.sh; do
    ssh -F "$INV_SSH_CONFIG" "$n" "sudo install -d -m 0755 /etc/keepalived && sudo tee /etc/keepalived/$s >/dev/null && sudo chmod 0755 /etc/keepalived/$s" < "$DIR/$s"
  done
  printf '%s\n' "$conf" | ssh -F "$INV_SSH_CONFIG" "$n" 'sudo tee /etc/keepalived/keepalived.conf.new >/dev/null && sudo keepalived -t -f /etc/keepalived/keepalived.conf.new && sudo mv /etc/keepalived/keepalived.conf.new /etc/keepalived/keepalived.conf && sudo chmod 0644 /etc/keepalived/keepalived.conf && sudo systemctl enable --now keepalived >/dev/null 2>&1 && sudo systemctl reload-or-restart keepalived && systemctl is-active keepalived'
done
sleep 4
echo "== VIP holder(s) (must be exactly one)"
for n in "${nodes[@]}"; do
  ssh -F "$INV_SSH_CONFIG" "$n" "ip -4 -br addr show dev wlan0 | grep -q ' $VIP/' && echo '  $n holds $VIP'" || true
done
