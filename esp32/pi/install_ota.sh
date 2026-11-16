#!/usr/bin/env bash
# install_ota.sh - install the read-only firmware server on THIS Pi (run with sudo
# from a copy of esp32/pi). Idempotent. Release files are pushed into
# /var/lib/om2m-ota/fw by scripts/ota/publish.sh (owner: the SSH user).
#   sudo ./install_ota.sh [release-owner]
set -euo pipefail
cd "$(dirname "$0")"
OWNER=${1:-${SUDO_USER:-user}}
install -d /opt/om2m-ota
install -m 0644 ota_server.py /opt/om2m-ota/
install -d -o "$OWNER" -g "$OWNER" -m 0755 /var/lib/om2m-ota /var/lib/om2m-ota/fw
install -m 0644 systemd/om2m-ota.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now om2m-ota.service
systemctl restart om2m-ota.service
sleep 1
systemctl is-active om2m-ota.service
code=$(python3 - <<'PY'
import urllib.request, urllib.error
try:
    urllib.request.urlopen("http://127.0.0.1:8070/etc/passwd", timeout=3)
    print("served")
except urllib.error.HTTPError as e:
    print(e.code)
PY
)
[[ $code == 404 ]] || { echo "FAIL: server answered '$code' for a path outside /fw"; exit 1; }
echo "ok: om2m-ota on :8070, outside paths 404"
