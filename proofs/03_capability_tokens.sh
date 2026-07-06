#!/usr/bin/env bash
cd "$(dirname "$0")/.." && source scripts/env.sh
clean() { sed 's/[│┌┐└┘├┤─╭╮╰╯|]//g; s/  */ /g; s/^ *//; /^$/d; s/^/    /'; }
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
d=json.load(sys.stdin); f=d.get('content',{})
ops=int(float(f.get('allowed_ops',0)))
nm=[]
if ops&1:nm.append('READ')
if ops&2:nm.append('WRITE')
if ops&4:nm.append('DELETE')
if ops&8:nm.append('ADMIN')
print('    objectId    :', d.get('objectId'))
own=d.get('owner',{})
print('    owner       :', own.get('AddressOwner', own) if isinstance(own,dict) else own)
print('    resource_id :', f.get('resource_id'))
print('    allowed_ops :', ops, '=', '+'.join(nm))
print('    max_uses    :', f.get('max_uses'))
"
echo
echo "=== NON-COPYABLE: the Move type has key+store but NO 'copy' ability ==="
echo
grep -n "struct CapToken" move/sources/cap_token.move | sed 's/^/    /'
echo "    (abilities 'key, store' - never 'copy' - so it cannot be duplicated)"
echo
echo "=== ACCESS WITH THE VALID TOKEN SUCCEEDS (live GRANT, real digest) ==="
echo
echo "\$ curl -X POST .../sui-das -H 'X-M2M-Operation: 5'   (decision request)"
echo
sshpass -p user ssh user@10.25.96.203 bash <<'EOF' | clean
BASE=http://127.0.0.1:8282; ORIG=admin:admin
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/~/in-cse/in-name/sui-das" -H "X-M2M-Origin: $ORIG")
if [ "$code" = "404" ]; then sudo systemctl start sui-das-provision.service 2>/dev/null; sleep 45; fi
curl -s -o /dev/null -w 'decision HTTP %{http_code}\n' -X POST "$BASE/~/in-cse/in-name/sui-das" \
  -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: proof3' -H 'X-M2M-Operation: 5' \
  -H 'Content-Type: application/json' \
  -d '{"m2m:sec":{"sit":1,"dreq":{"or":"admin:admin","op":1,"rid":"/in-cse/in-name/sui-protected-cnt","rty":3}}}'
sleep 3
docker logs --since 12s om2m-active 2>&1 | grep -iE 'Sui GRANT' | tail -1
EOF
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: the capability is a real on-chain object with a fixed resource"
echo "and ops mask; its Move type is non-copyable (linear); holding it yields a"
echo "verifiable on-chain GRANT with a transaction digest."
echo "--------------------------------------------------------------------------------"
