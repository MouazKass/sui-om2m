#!/usr/bin/env bash
# install-gas-watchdog.sh - install/upgrade the gas watchdog on THIS Pi (run with sudo).
# Usage: sudo ./install-gas-watchdog.sh   (from a directory holding the files below)
set -euo pipefail
cd "$(dirname "$0")"
command -v python3 >/dev/null
python3 -c 'import argon2.low_level' 2>/dev/null || \
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-argon2
install -m 755 gas-watchdog.py /usr/local/bin/sui-gas-watchdog
install -m 644 sui-gas-watchdog.service sui-gas-watchdog.timer /etc/systemd/system/
# Keep local overrides on upgrade.
[ -f /etc/default/sui-gas-watchdog ] || install -m 644 sui-gas-watchdog.default /etc/default/sui-gas-watchdog
install -d -m 750 /var/lib/sui-om2m/faucet
/usr/local/bin/sui-gas-watchdog --self-test
systemctl daemon-reload
systemctl enable --now sui-gas-watchdog.timer
systemctl list-timers sui-gas-watchdog.timer --no-pager | head -3
