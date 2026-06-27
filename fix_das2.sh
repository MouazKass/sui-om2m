#!/usr/bin/env bash
set -uo pipefail
RPI1=10.25.96.200; PW=user; BASE=http://127.0.0.1:8282
ssh1() { sshpass -p "$PW" ssh -o StrictHostKeyChecking=no user@$RPI1 "$@"; }

echo "=== 1. read the ACP by name, extract its real ri ==="
ACP_RI=$(ssh1 "curl -s '$BASE/~/in-cse/in-name/acp_admin' -H 'X-M2M-Origin: admin:admin' -H 'Accept: application/json'" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["m2m:acp"]["ri"])
except Exception as e: print("")')
echo "   ACP ri = $ACP_RI"
[ -z "$ACP_RI" ] && { echo "ERROR: could not read ACP ri"; exit 1; }

echo "=== 2. create AE with acpi=ri ==="
ssh1 "curl -s -X POST '$BASE/~/in-cse/in-name' -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-RI: a1' -H 'Content-Type: application/json;ty=2' -d '{\"m2m:ae\":{\"rn\":\"sui-das\",\"api\":\"N.sui-das.0001\",\"apn\":\"sui-das\",\"poa\":[\"sui-das\"],\"rr\":true,\"acpi\":[\"$ACP_RI\"]}}' -w '\nAE: HTTP %{http_code}\n'"

echo "=== 3. create container with acpi=ri ==="
ssh1 "curl -s -X POST '$BASE/~/in-cse/in-name' -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-RI: c1' -H 'Content-Type: application/json;ty=3' -d '{\"m2m:cnt\":{\"rn\":\"sui-protected-cnt\",\"acpi\":[\"$ACP_RI\"]}}' -w '\nCNT: HTTP %{http_code}\n'"

echo "=== 4. GRANT smoke test ==="
ssh1 "curl -s -X POST '$BASE/~/in-cse/in-name/sui-das' -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-RI: t1' -H 'Content-Type: application/json;ty=4' -d '{\"m2m:sec\":{\"sit\":1,\"dreq\":{\"or\":\"Csensor-001\",\"op\":1,\"rid\":\"/in-cse/in-name/sui-protected-cnt\",\"rty\":4}}}' -w '\nSMOKE: HTTP %{http_code}\n'"
echo "   --- GRANT log: ---"
ssh1 "docker logs --since 25s om2m-active 2>&1 | grep -iE 'Sui GRANT|digest|deny|abort' | tail -5"
