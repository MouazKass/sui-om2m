#!/usr/bin/env bash
# CONCEPT 3 - CAPABILITY TOKENS (CT1-CT6). Non-forgeable, non-copyable Move
# objects; access requires the token; the token names its resource + ops.
cd "$(dirname "$0")/.." && source scripts/env.sh
echo
echo "################################################################################"
echo "#  CONCEPT 3 - CAPABILITY TOKENS"
echo "################################################################################"
echo
echo "=== THE TOKEN AS AN ON-CHAIN OBJECT (owner, resource, ops mask) ==="
echo
echo "\$ sui client object $CAP_TOKEN_RPI3 --json"
echo
sui client object "$CAP_TOKEN_RPI3" --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
f=d.get('content',{})
print('    objectId    :', d.get('objectId'))
print('    owner       :', d.get('owner'))
print('    resource_id :', f.get('resource_id'))
print('    allowed_ops :', f.get('allowed_ops'), '(bitmask: 1=READ 2=WRITE 4=DELETE)')
print('    max_uses    :', f.get('max_uses'))
print('    type        :', d.get('objType','')[-45:])
" 2>/dev/null
echo
echo "=== NON-COPYABLE: the Move type has key+store but NO 'copy' ability ==="
echo
echo "\$ grep 'struct CapToken' move/sources/cap_token.move"
grep -n "struct CapToken" move/sources/cap_token.move | sed 's/^/    /'
echo "    (abilities are 'key, store' - never 'copy' - so it cannot be duplicated)"
echo
echo "=== ACCESS WITH THE VALID TOKEN SUCCEEDS (live GRANT, real digest) ==="
echo "    rpi3 owns the token for the protected resource; a decision request runs"
echo "    the full 6-step PTB and commits a GRANT on-chain."
echo
echo "\$ curl -X POST .../sui-das  -H 'X-M2M-Operation: 5'  (decision request)"
echo
sshpass -p user ssh user@10.25.96.203 bash <<'EOF' | sed 's/^/    /'
BASE=http://127.0.0.1:8282; ORIG=admin:admin
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/~/in-cse/in-name/sui-das" -H "X-M2M-Origin: $ORIG")
if [ "$code" = "404" ]; then sudo systemctl start sui-das-provision.service 2>/dev/null; sleep 45; fi
curl -s -o /dev/null -w 'decision HTTP %{http_code}\n' -X POST "$BASE/~/in-cse/in-name/sui-das" \
  -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: proof3' -H 'X-M2M-Operation: 5' \
  -H 'Content-Type: application/json' \
  -d '{"m2m:sec":{"sit":1,"dreq":{"or":"admin:admin","op":1,"rid":"/in-cse/in-name/sui-protected-cnt","rty":3}}}'
sleep 3
docker logs --since 12s om2m-active 2>&1 | grep -iE 'Sui GRANT|digest' | tail -1
EOF
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: the capability is a real on-chain object with a fixed resource"
echo "and ops mask; its Move type is non-copyable (linear); and holding it yields a"
echo "verifiable on-chain GRANT with a transaction digest."
echo "--------------------------------------------------------------------------------"
