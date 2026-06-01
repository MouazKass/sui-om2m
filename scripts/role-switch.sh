#!/bin/sh
ROLE="$1"
POA="$2"
echo "[role-switch] called with role=$ROLE poa=$POA"
# Run worker detached
setsid /root/role-switch-worker.sh "$ROLE" "$POA" < /dev/null > /var/log/role-switch.log 2>&1 &
echo "[role-switch] worker spawned, returning"
exit 0
