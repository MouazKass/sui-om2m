#!/bin/sh
# is_parent.sh - keepalived weight check: succeeds only while THIS node is the
# cluster's current parent on-chain. It reads <state_dir>/parent.json, which
# the ESP bridge rewrites after every chain poll (parent_poll_s), so no extra
# chain query is made. A stale file (bridge stuck or chain unreadable for
# 30 s) counts as "not parent", and the VIP goes back to plain priority order.
F=${PARENT_JSON:-/var/lib/om2m-ipe-bridge/parent.json}
exec python3 -I -c '
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("is_self") is True and time.time() - d.get("ts", 0) <= 30 else 1)
' "$F"
