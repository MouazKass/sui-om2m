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
# per-device identity (esp_identity.py) verifies Ed25519 with python3-cryptography
python3 -c 'from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey' 2>/dev/null || {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-cryptography; }
command -v mosquitto_pub >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -q mosquitto-clients
install -d /opt/om2m-ipe-bridge /etc/om2m-ipe-bridge
# Dedicated service user (v2.2): it owns the ack key and the replay floor in
# /var/lib/om2m-ipe-bridge, which a shared "nobody" must not be able to read.
getent passwd om2m-ipe >/dev/null || useradd --system --no-create-home --home-dir /nonexistent \
  --shell /usr/sbin/nologin om2m-ipe
install -d -o om2m-ipe -g om2m-ipe -m 0700 /var/lib/om2m-ipe-bridge
# Upgrading from Hamza's v1 bridge (no [cluster] section): keep a copy of the v1
# code and config, then start from the v2 template. Reverse with the backup dir.
if [[ -f /etc/om2m-ipe-bridge/bridge.conf ]] && ! grep -q '^\[cluster\]' /etc/om2m-ipe-bridge/bridge.conf; then
  B=/etc/om2m-ipe-bridge/v1-backup-$(date +%Y%m%d-%H%M%S)
  install -d "$B"
  cp -a /etc/om2m-ipe-bridge/bridge.conf "$B/"
  [[ -f /opt/om2m-ipe-bridge/om2m_ipe_bridge.py ]] && cp -a /opt/om2m-ipe-bridge/om2m_ipe_bridge.py "$B/"
  rm -f /etc/om2m-ipe-bridge/bridge.conf
  echo "v1 bridge found: code + config backed up to $B"
fi
install -m 0755 om2m_ipe_bridge.py /opt/om2m-ipe-bridge/
install -m 0644 esp_identity.py /opt/om2m-ipe-bridge/
MEM=members.conf; [[ -f $MEM ]] || MEM=members.conf.example
install -m 0644 "$MEM" /etc/om2m-ipe-bridge/members.conf
if [[ ! -f /etc/om2m-ipe-bridge/bridge.conf ]]; then
  install -m 0644 bridge.conf.example /etc/om2m-ipe-bridge/bridge.conf
fi
# Per-node values, and the chain ids from this node's own plugin config
# (read here, as root: the service runs as om2m-ipe and cannot read ~user).
PROPS=$(getent passwd user | cut -d: -f6)/sui-runtime-config/sui.properties
prop() { grep -E "^$1=" "$PROPS" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]'; }
CL=$(prop sui.failover.cluster.id); PKG=$(prop sui.package.original.id); [[ -n "$PKG" ]] || PKG=$(prop sui.package.id)
GQL=$(prop sui.graphql.url)
sed -i -E "s|^client_id *=.*|client_id = om2m-ipe-bridge-$NODE|; s|^node_label *=.*|node_label = $NODE|; \
           s|^self *=.*|self = $NODE|" /etc/om2m-ipe-bridge/bridge.conf
if [[ -n "$CL" && -n "$PKG" ]]; then
  sed -i -E "s|^cluster_id *=.*|cluster_id = $CL|; s|^package_original_id *=.*|package_original_id = $PKG|" \
    /etc/om2m-ipe-bridge/bridge.conf
  [[ -n "$GQL" ]] && sed -i -E "s|^graphql_url *=.*|graphql_url = $GQL|" /etc/om2m-ipe-bridge/bridge.conf
else
  echo "WARNING: no cluster/package id in $PROPS; falling back to target = local"
  sed -i -E "s|^target *=.*|target = local|" /etc/om2m-ipe-bridge/bridge.conf
fi
# [identity] (v2.1): added to configs that predate it; registry id from the plugin config.
if ! grep -q '^\[identity\]' /etc/om2m-ipe-bridge/bridge.conf; then
  sed -n '/^\[identity\]/,/^\[bridge\]/p' bridge.conf.example | sed '$d' >> /etc/om2m-ipe-bridge/bridge.conf
  echo "added [identity] section (mode = require)"
fi
# [ack] and bridge.state_dir (v2.2): added to configs that predate them.
if ! grep -q '^\[ack\]' /etc/om2m-ipe-bridge/bridge.conf; then
  { echo; sed -n '/^\[ack\]/,/^\[bridge\]/p' bridge.conf.example | sed '$d'; } >> /etc/om2m-ipe-bridge/bridge.conf
  echo "added [ack] section (sign = true)"
fi
grep -q '^state_dir *=' /etc/om2m-ipe-bridge/bridge.conf || \
  sed -i -E '/^\[bridge\]/a state_dir = /var/lib/om2m-ipe-bridge' /etc/om2m-ipe-bridge/bridge.conf
REG=$(prop sui.identity.registry.id)
if [[ -n "$REG" ]]; then
  sed -i -E "s|^registry_id *=.*|registry_id = $REG|" /etc/om2m-ipe-bridge/bridge.conf
else
  echo "WARNING: no sui.identity.registry.id in $PROPS; identity.mode = require will refuse to start"
fi
install -m 0644 systemd/om2m-ipe-bridge.service /etc/systemd/system/
# The ack key is generated HERE, as the service user, and never leaves this Pi.
# Only its public half is printed (pin it on the boards: deploy/v9/ack_keys/).
ACK=$(runuser -u om2m-ipe -- python3 /opt/om2m-ipe-bridge/om2m_ipe_bridge.py \
        -c /etc/om2m-ipe-bridge/bridge.conf --print-ack-key)
echo "ack key: $ACK"
systemctl daemon-reload
systemctl enable om2m-ipe-bridge >/dev/null
systemctl restart om2m-ipe-bridge
sleep 2
systemctl is-active om2m-ipe-bridge
grep -E "^(self|target|cluster_id|package_original_id|mode|registry_id) =" /etc/om2m-ipe-bridge/bridge.conf
