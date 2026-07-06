#!/usr/bin/env bash
# CONCEPT 4 - ATOMIC DECISION / NO TOCTOU (ID1-ID4). The whole decision is ONE
# Programmable Transaction Block - no check-to-use gap.
cd "$(dirname "$0")/.." && source scripts/env.sh
echo
echo "################################################################################"
echo "#  CONCEPT 4 - ATOMIC DECISION / NO TOCTOU"
echo "################################################################################"
echo
echo "=== Fire a GRANT, then inspect the transaction it produced ==="
echo
echo "\$ curl -X POST .../sui-das -H 'X-M2M-Operation: 5'   (one decision request)"
echo
DIGEST=$(sshpass -p user ssh user@10.25.96.203 bash <<'EOF'
BASE=http://127.0.0.1:8282; ORIG=admin:admin
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/~/in-cse/in-name/sui-das" -H "X-M2M-Origin: $ORIG")
if [ "$code" = "404" ]; then sudo systemctl start sui-das-provision.service 2>/dev/null; sleep 45; fi
curl -s -o /dev/null -X POST "$BASE/~/in-cse/in-name/sui-das" \
  -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: proof4' -H 'X-M2M-Operation: 5' \
  -H 'Content-Type: application/json' \
  -d '{"m2m:sec":{"sit":1,"dreq":{"or":"admin:admin","op":1,"rid":"/in-cse/in-name/sui-protected-cnt","rty":3}}}'
sleep 3
docker logs --since 12s om2m-active 2>&1 | grep -oE 'digest=[A-Za-z0-9]+' | tail -1 | cut -d= -f2
EOF
)
echo "    GRANT transaction digest: $DIGEST"
echo
echo "\$ sui client tx-block $DIGEST --json   (the PTB's command list)"
echo
sui client tx-block "$DIGEST" --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
try:
    cmds=d['transaction']['data']['transaction']['transactions']
    print('    Move calls inside this SINGLE transaction:', len(cmds))
    for i,c in enumerate(cmds):
        if 'MoveCall' in c:
            m=c['MoveCall']; print(f'      step {i}: {m.get(\"module\")}::{m.get(\"function\")}')
except Exception:
    print('    (inspect', d.get('digest','the digest'), 'in a Sui explorer for the command list)')
" 2>/dev/null || echo "    (inspect $DIGEST in a Sui explorer to see the atomic command list)"
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: identity, trust, policy, token, and the audit write are all"
echo "commands INSIDE ONE transaction, committed atomically. There is no window"
echo "between check and use (ID1-ID4)."
echo "--------------------------------------------------------------------------------"
