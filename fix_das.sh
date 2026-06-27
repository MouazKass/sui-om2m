#!/usr/bin/env bash
set -uo pipefail
RPI1=10.25.96.200; PW=user; BASE=http://127.0.0.1:8282
ssh1() { sshpass -p "$PW" ssh -o StrictHostKeyChecking=no user@$RPI1 "$@"; }

echo "=== 1. restart container (clears in-memory bad resources) ==="
ssh1 "docker restart om2m-active"
echo "   waiting 35s..."; sleep 35

echo "=== 2. CSE serving? ==="
ssh1 "curl -s -o /dev/null -w 'CSE: HTTP %{http_code}\n' '$BASE/~/in-cse' -H 'X-M2M-Origin: admin:admin'"

echo "=== 3. discover the ACP ri (regenerated each boot) ==="
ACP_RI=$(ssh1 "curl -s '$BASE/~/in-cse?fu=1&ty=1' -H 'X-M2M-Origin: admin:admin' -H 'Accept: application/json'" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["m2m:uril"][0])
except Exception: print("")')
echo "   ACP = $ACP_RI"
[ -z "$ACP_RI" ] && { echo "   ERROR: no ACP found, aborting"; exit 1; }

echo "=== 4. create AE with acpi from birth ==="
ssh1 "curl -s -X POST '$BASE/~/in-cse/in-name' -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-RI: a1' -H 'Content-Type: application/json;ty=2' -d '{\"m2m:ae\":{\"rn\":\"sui-das\",\"api\":\"N.sui-das.0001\",\"apn\":\"sui-das\",\"poa\":[\"sui-das\"],\"rr\":true,\"acpi\":[\"$ACP_RI\"]}}' -w '\nAE: HTTP %{http_code}\n'"

echo "=== 5. create container with acpi from birth ==="
ssh1 "curl -s -X POST '$BASE/~/in-cse/in-name' -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-RI: c1' -H 'Content-Type: application/json;ty=3' -d '{\"m2m:cnt\":{\"rn\":\"sui-protected-cnt\",\"acpi\":[\"$ACP_RI\"]}}' -w '\nCNT: HTTP %{http_code}\n'"

echo "=== 6. GRANT smoke test ==="
ssh1 "curl -s -X POST '$BASE/~/in-cse/in-name/sui-das' -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-RI: t1' -H 'Content-Type: application/json;ty=4' -d '{\"m2m:sec\":{\"sit\":1,\"dreq\":{\"or\":\"Csensor-001\",\"op\":1,\"rid\":\"/in-cse/in-name/sui-protected-cnt\",\"rty\":4}}}' -w '\nSMOKE: HTTP %{http_code}\n'"
echo "   --- GRANT log: ---"
ssh1 "docker logs --since 25s om2m-active 2>&1 | grep -iE 'Sui GRANT|digest|deny|abort' | tail -10"
