#!/usr/bin/env bash
# Installs or upgrades the bridge as a systemd service on THIS Raspberry Pi.
# Run from this folder:  sudo ./install.sh <node-label>
# Keeps an existing /etc/om2m-ipe-bridge/bridge.conf; members.conf is always
# refreshed from this folder (it is the same file on every node).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
NODE=${1:?usage: sudo ./install.sh <node-label, e.g. rpi2>}
cd "$(dirname "$0")"
python3 -c 'import paho.mqtt, requests' 2>/dev/null || {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-paho-mqtt python3-requests; }
command -v mosquitto_pub >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -q mosquitto-clients
install -d /opt/om2m-ipe-bridge /etc/om2m-ipe-bridge
install -m 0755 om2m_ipe_bridge.py /opt/om2m-ipe-bridge/
MEM=members.conf; [[ -f $MEM ]] || MEM=members.conf.example
install -m 0644 "$MEM" /etc/om2m-ipe-bridge/members.conf
if [[ ! -f /etc/om2m-ipe-bridge/bridge.conf ]]; then
  install -m 0644 bridge.conf.example /etc/om2m-ipe-bridge/bridge.conf
fi
# Per-node values, and the chain ids from this node's own plugin config
# (read here, as root: the service runs as nobody and cannot read ~user).
PROPS=$(getent passwd user | cut -d: -f6)/sui-runtime-config/sui.properties
prop() { grep -E "^$1=" "$PROPS" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]'; }
CL=$(prop sui.failover.cluster.id); PKG=$(prop sui.package.original.id); [[ -n "$PKG" ]] || PKG=$(prop sui.package.id)
GQL=$(prop sui.graphql.url)
sed -i -E "s|^client_id = .*|client_id = om2m-ipe-bridge-$NODE|; s|^node_label = .*|node_label = $NODE|; \
           s|^self = .*|self = $NODE|" /etc/om2m-ipe-bridge/bridge.conf
if [[ -n "$CL" && -n "$PKG" ]]; then
  sed -i -E "s|^cluster_id = .*|cluster_id = $CL|; s|^package_original_id = .*|package_original_id = $PKG|" \
    /etc/om2m-ipe-bridge/bridge.conf
  [[ -n "$GQL" ]] && sed -i -E "s|^graphql_url = .*|graphql_url = $GQL|" /etc/om2m-ipe-bridge/bridge.conf
else
  echo "WARNING: no cluster/package id in $PROPS; falling back to target = local"
  sed -i -E "s|^target = .*|target = local|" /etc/om2m-ipe-bridge/bridge.conf
fi
install -m 0644 systemd/om2m-ipe-bridge.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable om2m-ipe-bridge >/dev/null
systemctl restart om2m-ipe-bridge
sleep 2
systemctl is-active om2m-ipe-bridge
grep -E "^(self|target|cluster_id|package_original_id) =" /etc/om2m-ipe-bridge/bridge.conf
