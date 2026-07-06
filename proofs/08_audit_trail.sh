#!/usr/bin/env bash
# CONCEPT 8 - AUDIT TRAIL (SY1-SY5). Every decision emits an event onto an
# append-only on-chain trail; no edit/delete path exists.
cd "$(dirname "$0")/.." && source scripts/env.sh
echo
echo "################################################################################"
echo "#  CONCEPT 8 - AUDIT TRAIL"
echo "################################################################################"
echo
echo "=== THE AUDIT TRAIL OBJECT ON-CHAIN ==="
echo
echo "\$ sui client object $AUDIT_TRAIL --json"
echo
sui client object "$AUDIT_TRAIL" --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('    trail id:', d.get('objectId'))
print('    owner   :', d.get('owner'))
print('    type    :', d.get('objType','')[-45:])
" 2>/dev/null
echo
echo "=== A FRESH DECISION EMITS AN EVENT (read the tx's events) ==="
echo
DIGEST=$(sshpass -p user ssh user@10.25.96.203 bash <<'EOF'
BASE=http://127.0.0.1:8282; ORIG=admin:admin
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/~/in-cse/in-name/sui-das" -H "X-M2M-Origin: $ORIG")
if [ "$code" = "404" ]; then sudo systemctl start sui-das-provision.service 2>/dev/null; sleep 45; fi
curl -s -o /dev/null -X POST "$BASE/~/in-cse/in-name/sui-das" \
  -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: proof8' -H 'X-M2M-Operation: 5' \
  -H 'Content-Type: application/json' \
  -d '{"m2m:sec":{"sit":1,"dreq":{"or":"admin:admin","op":1,"rid":"/in-cse/in-name/sui-protected-cnt","rty":3}}}'
sleep 3
docker logs --since 12s om2m-active 2>&1 | grep -oE 'digest=[A-Za-z0-9]+' | tail -1 | cut -d= -f2
EOF
)
echo "    decision digest: $DIGEST"
echo "\$ sui client tx-block $DIGEST --json   (events emitted)"
echo
sui client tx-block "$DIGEST" --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
evs=d.get('events',[])
print('    events emitted:', len(evs))
for e in evs:
    print('      type:', e.get('type','')[-55:])
    pj=e.get('parsedJson',{})
    if pj: print('      data:', json.dumps(pj)[:200])
" 2>/dev/null || echo "    (inspect $DIGEST in a Sui explorer to see the emitted event)"
echo
echo "=== IMMUTABILITY IS STRUCTURAL (audit module exposes log/count only) ==="
echo
echo "\$ grep -n 'public.*fun' move/sources/audit.move"
grep -nE "public.*fun " move/sources/audit.move | head -8 | sed 's/^/    /'
echo "    (log/resize/count/decision_* only - no edit or delete of a past record)"
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: the trail is an on-chain object; each decision emits an"
echo "on-chain event carrying the record; and the module has no edit/delete path, so"
echo "records are append-only and tamper-evident."
echo "--------------------------------------------------------------------------------"
