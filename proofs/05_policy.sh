#!/usr/bin/env bash
# CONCEPT 5 - POLICY ENFORCEMENT (PO1-PO4). Access gated by min-trust + ops mask;
# a request without a matching capability is DENIED (fail-closed).
cd "$(dirname "$0")/.." && source scripts/env.sh
echo
echo "################################################################################"
echo "#  CONCEPT 5 - POLICY ENFORCEMENT"
echo "################################################################################"
echo
echo "=== THE POLICY OBJECT ON-CHAIN (resource -> min_trust, ops mask) ==="
echo
echo "\$ sui client object $POLICY_REG --json"
echo
sui client object "$POLICY_REG" --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('    objectId:', d.get('objectId'))
f=d.get('content',{})
print('    fields  :', json.dumps(f)[:300])
" 2>/dev/null
echo "    (policy for /in-cse/in-name/sui-protected-cnt: min_trust=50, ops=3)"
echo
echo "=== A REQUEST FROM A NODE THAT IS NOT THE TOKEN OWNER = DENY (fail-closed) ==="
echo "    rpi1 asks for a decision on the resource whose token rpi3 owns."
echo
echo "\$ curl -X POST .../sui-das -H 'X-M2M-Operation: 5'   (from rpi1)"
echo
sshpass -p user ssh user@10.25.96.200 bash <<'EOF' | sed 's/^/    /'
BASE=http://127.0.0.1:8282; ORIG=admin:admin
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/~/in-cse/in-name/sui-das" -H "X-M2M-Origin: $ORIG")
if [ "$code" = "404" ]; then sudo systemctl start sui-das-provision.service 2>/dev/null; sleep 45; fi
curl -s -o /dev/null -w 'decision HTTP %{http_code}\n' -X POST "$BASE/~/in-cse/in-name/sui-das" \
  -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: proof5' -H 'X-M2M-Operation: 5' \
  -H 'Content-Type: application/json' \
  -d '{"m2m:sec":{"sit":1,"dreq":{"or":"admin:admin","op":1,"rid":"/in-cse/in-name/sui-protected-cnt","rty":3}}}'
sleep 3
docker logs --since 12s om2m-active 2>&1 | grep -iE 'Sui DENY|Sui GRANT|no sui mapping|reason' | tail -2
EOF
echo
echo "=== THE MIN-TRUST GATE IS ON-CHAIN LOGIC (policy.evaluate source) ==="
echo
echo "\$ grep -n 'E_TRUST_BELOW_MIN\|E_OP_DENIED\|min_trust' move/sources/policy.move"
grep -nE "E_TRUST_BELOW_MIN|E_OP_DENIED|min_trust" move/sources/policy.move | head -5 | sed 's/^/    /'
echo "    (abort code 3 = E_TRUST_BELOW_MIN, code 2 = E_OP_DENIED)"
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: the policy (min_trust, ops mask) is on-chain; a node without a"
echo "matching capability is DENIED (fail-closed); the trust gate is enforced in the"
echo "policy contract, not off-chain."
echo "--------------------------------------------------------------------------------"
