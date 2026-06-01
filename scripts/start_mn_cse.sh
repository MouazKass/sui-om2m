#!/bin/sh
set -e
P=/root/git/org.eclipse.om2m/org.eclipse.om2m.site.mn-cse/target/products/mn-cse/linux/gtk/aarch64
CONFIG=$P/configuration/config.ini

PARENT_IP=""
if [ -n "$CURRENT_PARENT_POA" ]; then
  PARENT_IP=$(echo "$CURRENT_PARENT_POA" | sed -E "s|^https?://([^:/]+).*|\1|")
elif [ -f /tmp/current-parent-poa ]; then
  POA=$(cat /tmp/current-parent-poa)
  PARENT_IP=$(echo "$POA" | sed -E "s|^https?://([^:/]+).*|\1|")
fi

if [ -z "$PARENT_IP" ]; then
  echo "ERROR: no parent IP available"
  exit 1
fi

echo "[mn-startup] Resolved parent IP: $PARENT_IP"
sed -i "s|__PARENT_IP_PLACEHOLDER__|$PARENT_IP|g" $CONFIG
exec /root/start_scripts/start_arm64.sh "$@"
