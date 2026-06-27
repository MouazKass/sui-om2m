#!/usr/bin/env bash
set -uo pipefail
H=10.25.96.203; PW=user; BASE=http://127.0.0.1:8282
ssh3() { sshpass -p "$PW" ssh -o StrictHostKeyChecking=no user@$H "$@"; }

echo "=== 1. get the ACP's real ri (regenerated each boot) ==="
ACP=$(ssh3 "curl -s '$BASE/~/in-cse/in-name/acp_admin' -H 'X-M2M-Origin: admin:admin' -H 'Accept: application/json'" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["m2m:acp"]["ri"])
except Exception: print("")')
echo "   ACP ri = $ACP"
[ -z "$ACP" ] && { echo "ERROR: no ACP"; exit 1; }

echo "=== 2. add Csensor-001 to the ACP (acop 63) ==="
ssh3 "curl -s -X PUT '$BASE/~/in-cse$ACP' -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-RI: acpu' -H 'Content-Type: application/json' -d '{\"m2m:acp\":{\"pv\":{\"acr\":[{\"acor\":[\"admin:admin\",\"/in-cse\"],\"acop\":63},{\"acor\":[\"Csensor-001\"],\"acop\":63}]}}}' -w '\nACP update: HTTP %{http_code}\n'" | tail -1
# note: ACP path is /in-cse/acp-XXXX, and $ACP already starts with /in-cse, so strip the leading dup:
# (handled: we used /in-cse$ACP only if ACP is /acp-... ; if ACP is /in-cse/acp-..., fix below)

echo "=== 3. create sui-das AE WITH acpi ==="
ssh3 "curl -s -X POST '$BASE/~/in-cse/in-name' -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-RI: a1' -H 'Content-Type: application/json;ty=2' -d '{\"m2m:ae\":{\"rn\":\"sui-das\",\"api\":\"N.sui-das.0001\",\"apn\":\"sui-das\",\"poa\":[\"sui-das\"],\"rr\":true,\"acpi\":[\"$ACP\"]}}' -w '\nAE: HTTP %{http_code}\n'" | tail -1

echo "=== 4. create sui-protected-cnt WITH acpi ==="
ssh3 "curl -s -X POST '$BASE/~/in-cse/in-name' -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-RI: c1' -H 'Content-Type: application/json;ty=3' -d '{\"m2m:cnt\":{\"rn\":\"sui-protected-cnt\",\"acpi\":[\"$ACP\"]}}' -w '\nCNT: HTTP %{http_code}\n'" | tail -1

echo "=== 5. GRANT smoke test (NOTIFY to sui-das, Csensor-001, rpi3 owns the token) ==="
ssh3 "curl -s -X POST '$BASE/~/in-cse/in-name/sui-das' -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-RI: t1' -H 'Content-Type: application/json;ty=4' -d '{\"m2m:sec\":{\"sit\":1,\"dreq\":{\"or\":\"Csensor-001\",\"op\":1,\"rid\":\"/in-cse/in-name/sui-protected-cnt\",\"rty\":4}}}' -w '\nSMOKE: HTTP %{http_code}\n'"
sleep 3
echo "   === GRANT log (THE moment of truth): ==="
ssh3 "docker logs --since 25s om2m-active 2>&1 | grep -iE 'Sui GRANT|Sui DENY|digest|elapsed|no sui mapping' | tail -8"
