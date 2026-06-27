#!/usr/bin/env bash
# provision_das.sh - one-command DAS recovery after any reboot/restart.
# Recreates the in-memory OM2M resources (AE + protected container) WITH the ACP
# attached from birth, adds the test originator to the ACP, and fires a GRANT to
# verify the full on-chain path. Run from the laptop; targets a node via sshpass.
#
# Usage:  ./provision_das.sh [node_ip]      (default rpi3 = the GRANT-capable node)
#
# Why each step: OM2M's resource DB is in-memory (lost on restart); a resource
# created with no ACP locks itself out of UPDATE/DELETE, so acpi MUST be set at
# creation; the ACP's ri is regenerated each boot so we discover it fresh; and the
# GRANT trigger REQUIRES the X-M2M-Operation: 5 header (else OM2M 403s at checkACP).
set -uo pipefail

NODE="${1:-10.25.96.203}"
PW="${PW:-user}"
ORIG="${ORIG:-admin:admin}"          # originator that owns a valid CapToken on this node
BASE=http://127.0.0.1:8282
ssh_n() { sshpass -p "$PW" ssh -o StrictHostKeyChecking=no user@$NODE "$@"; }

echo "# provision_das.sh  node=$NODE  $(date -u +%H:%M:%SZ)"

echo "=== 1. CSE serving? ==="
ssh_n "curl -s -o /dev/null -w '   CSE: HTTP %{http_code}\n' '$BASE/~/in-cse' -H 'X-M2M-Origin: $ORIG'"

echo "=== 2. discover ACP ri (regenerated each boot) ==="
ACP=$(ssh_n "curl -s '$BASE/~/in-cse/in-name/acp_admin' -H 'X-M2M-Origin: $ORIG' -H 'Accept: application/json'" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["m2m:acp"]["ri"])
except Exception: print("")')
[ -z "$ACP" ] && { echo "   ERROR: acp_admin not found"; exit 1; }
echo "   ACP = $ACP"

echo "=== 3. ensure originator in ACP (acop 63) ==="
ssh_n "curl -s -o /dev/null -w '   ACP update: HTTP %{http_code}\n' -X PUT '$BASE/~$ACP' -H 'X-M2M-Origin: $ORIG' -H 'X-M2M-RI: acpu' -H 'Content-Type: application/json' -d '{\"m2m:acp\":{\"pv\":{\"acr\":[{\"acor\":[\"admin:admin\",\"/in-cse\"],\"acop\":63},{\"acor\":[\"Csensor-001\"],\"acop\":63}]}}}'"

echo "=== 4. create sui-das AE (acpi from birth) ==="
ssh_n "curl -s -o /dev/null -w '   AE: HTTP %{http_code}\n' -X POST '$BASE/~/in-cse/in-name' -H 'X-M2M-Origin: $ORIG' -H 'X-M2M-RI: a1' -H 'Content-Type: application/json;ty=2' -d '{\"m2m:ae\":{\"rn\":\"sui-das\",\"api\":\"N.sui-das.0001\",\"apn\":\"sui-das\",\"poa\":[\"sui-das\"],\"rr\":true,\"acpi\":[\"$ACP\"]}}'"

echo "=== 5. create sui-protected-cnt (acpi from birth) ==="
ssh_n "curl -s -o /dev/null -w '   CNT: HTTP %{http_code}\n' -X POST '$BASE/~/in-cse/in-name' -H 'X-M2M-Origin: $ORIG' -H 'X-M2M-RI: c1' -H 'Content-Type: application/json;ty=3' -d '{\"m2m:cnt\":{\"rn\":\"sui-protected-cnt\",\"acpi\":[\"$ACP\"]}}'"

echo "=== 6. GRANT smoke test (X-M2M-Operation: 5 is REQUIRED) ==="
ssh_n "curl -s -o /dev/null -w '   SMOKE: HTTP %{http_code}\n' -X POST '$BASE/~/in-cse/in-name/sui-das' -H 'X-M2M-Origin: $ORIG' -H 'X-M2M-RI: fire' -H 'X-M2M-Operation: 5' -H 'Content-Type: application/json' -d '{\"m2m:sec\":{\"sit\":1,\"dreq\":{\"or\":\"$ORIG\",\"op\":1,\"rid\":\"/in-cse/in-name/sui-protected-cnt\",\"rty\":3}}}'"
sleep 3
echo "   --- result: ---"
ssh_n "docker logs --since 20s om2m-active 2>&1 | grep -iE 'Sui GRANT|Sui DENY|no sui mapping' | tail -3"
echo ""
echo "# Done. If you saw 'Sui GRANT ... (NNNN ms)', the system is live."
