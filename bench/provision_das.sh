#!/usr/bin/env bash
# provision_das.sh - one-command DAS recovery after any reboot/restart.
# Recreates the in-memory OM2M resources (AE + protected container) WITH the ACP
# attached from birth, adds the test originator to the ACP, and fires a GRANT to
# verify the full on-chain path. Run from the laptop; targets a node via sshpass.
#
# Usage:  ./provision_das.sh [node_ip]      (default: the das=yes node in deploy/inventory.tsv, the GRANT-capable node)
#
# Why each step: OM2M's resource DB is in-memory (lost on restart); a resource
# created with no ACP locks itself out of UPDATE/DELETE, so acpi MUST be set at
# creation; the ACP's ri is regenerated each boot so we discover it fresh; and the
# GRANT trigger REQUIRES the X-M2M-Operation: 5 header (else OM2M 403s at checkACP).
set -uo pipefail
INV_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${REPO:-$INV_REPO}"
# shellcheck source=../scripts/lib/inventory.sh
. "$INV_REPO/scripts/lib/inventory.sh"; inv_load   # nodes: deploy/inventory.tsv

# SUPERSEDED in v8 by deploy/v8/host/provision-das.sh (installed on every node,
# run at boot by sui-das-provision.service). This legacy script re-adds
# Csensor-001 with acop 63 to acp_admin (step "ACP update" below) - the static
# grant that let Csensor-001 bypass the chain, removed in the v8 rollout. It
# refuses to run unless you explicitly opt in, e.g. for a v7 rollback.
if [ "${LEGACY_V7_PROVISION:-0}" != 1 ]; then
  echo "refusing: superseded by deploy/v8/host/provision-das.sh (re-opens the Csensor-001 static ACP bypass)." >&2
  echo "  on the node: sudo /usr/local/bin/provision-das.sh   |  override: LEGACY_V7_PROVISION=1 $0" >&2
  exit 2
fi

NODE="${1:-${INV_IP[$(inv_das)]}}"
PW="${PW:-user}"
ORIG="${ORIG:-admin:admin}"          # originator that owns a valid CapToken on this node
BASE=http://127.0.0.1:8282
ssh_n() { ssh -F "$INV_SSH_CONFIG" -i "${SSH_KEY:-$HOME/.ssh/id_ed25519_suiom2m}" -o BatchMode=yes user@"$NODE" "$@"; }   # v8: key auth (password automation removed)

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

# =====================================================================
# PART B - native oneM2M dynamic-authorization path (C2)
#
# Steps 1-6 above exercise the DAS over a hand-crafted HTTP NOTIFY aimed
# straight at the sui-das AE. That proves the Sui decision engine works,
# but it does NOT prove the CSE consults it on an ordinary request.
#
# Part B provisions the real oneM2M wiring so that an ORDINARY request,
# with no special headers, is routed to the Sui DAS by OM2M itself:
#
#   acp_sui_dac   restrictive ACP - grants 63 to admin ONLY. The test
#                 originator appears nowhere, so the static check FAILS.
#   sui-dac       <dynamicAuthorizationConsultation> (ty=34) whose
#                 dap (dynamicAuthorizationPoA) is the sui-das AE's ri.
#   sui-dac-ae    <AE> (ty=2) carrying acpi=[acp_sui_dac] and
#                 daci=[sui-dac]. This is the DAC-protected resource.
#
# Why an AE and not a container: in org.eclipse.om2m.core only the
# controllers that call Controller.checkPermissions consult DACs
# (AE, AEAnnc, FlexContainer, FlexContainerAnnc, MgmtObj, MgmtObjAnnc,
# Node, Discovery). ContainerController calls the plain checkACP and is
# NEVER dynamically authorized, so a <container> cannot be DAS-protected
# on this stack. See C2_FINDINGS.md.
#
# Flow on an ordinary RETRIEVE of sui-dac-ae by $DAC_ORIG:
#   AEController.doRetrieve -> checkPermissions
#     -> checkACP(acp_sui_dac)           FAILS  (originator not listed)
#     -> DynamicAuthorizationSelector.authorize(daces of sui-dac-ae)
#     -> NOTIFY(SecurityInfo) to dap -> Redirector.retargetNotify
#     -> IpeSelector -> SuiDasService.doExecute   (in-JVM, typed object)
#     -> atomic 6-step PTB on Sui -> GRANT/DENY
# =====================================================================

DAC_ORIG="${DAC_ORIG:-Csensor-001}"   # originator used for the DAC probe

echo "=== 7. create restrictive ACP acp_sui_dac (grants NOTHING to $DAC_ORIG) ==="
ssh_n "curl -s -o /dev/null -w '   ACP(dac): HTTP %{http_code}\n' -X POST '$BASE/~/in-cse/in-name' -H 'X-M2M-Origin: $ORIG' -H 'X-M2M-RI: acpd' -H 'Content-Type: application/json;ty=1' -d '{\"m2m:acp\":{\"rn\":\"acp_sui_dac\",\"pv\":{\"acr\":[{\"acor\":[\"admin:admin\",\"/in-cse\"],\"acop\":63}]},\"pvs\":{\"acr\":[{\"acor\":[\"admin:admin\",\"/in-cse\"],\"acop\":63}]}}}'"

ACP_DAC=$(ssh_n "curl -s '$BASE/~/in-cse/in-name/acp_sui_dac' -H 'X-M2M-Origin: $ORIG' -H 'Accept: application/json'" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["m2m:acp"]["ri"])
except Exception: print("")')
[ -z "$ACP_DAC" ] && { echo "   ERROR: acp_sui_dac not found"; exit 1; }
echo "   ACP_DAC = $ACP_DAC"

echo "=== 8. discover sui-das AE ri (this is the dap value) ==="
# Redirector.retargetNotify resolves dap via getAeDAO().find(tx, To), which is
# keyed by resourceID -- so dap MUST be the AE's ri, not its hierarchical path.
DAS_AE_RI=$(ssh_n "curl -s '$BASE/~/in-cse/in-name/sui-das' -H 'X-M2M-Origin: $ORIG' -H 'Accept: application/json'" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["m2m:ae"]["ri"])
except Exception: print("")')
[ -z "$DAS_AE_RI" ] && { echo "   ERROR: sui-das AE not found (step 4 failed?)"; exit 1; }
echo "   DAS_AE_RI = $DAS_AE_RI"

echo "=== 9. create <dynamicAuthorizationConsultation> sui-dac (ty=34) ==="
# dae (dynamicAuthorizationEnabled) is MANDATORY -
# DynamicAuthorizationConsultationController rejects the create without it,
# and DynamicAuthorizationSelector skips any dace whose dae is false.
ssh_n "curl -s -o /dev/null -w '   DAC: HTTP %{http_code}\n' -X POST '$BASE/~/in-cse/in-name' -H 'X-M2M-Origin: $ORIG' -H 'X-M2M-RI: dac1' -H 'Content-Type: application/json;ty=34' -d '{\"m2m:dac\":{\"rn\":\"sui-dac\",\"dae\":true,\"dap\":[\"$DAS_AE_RI\"],\"acpi\":[\"$ACP\"]}}'"

DAC_RI=$(ssh_n "curl -s '$BASE/~/in-cse/in-name/sui-dac' -H 'X-M2M-Origin: $ORIG' -H 'Accept: application/json'" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["m2m:dac"]["ri"])
except Exception: print("")')
[ -z "$DAC_RI" ] && { echo "   ERROR: sui-dac not created - does this OM2M build have ty=34? See C2_FINDINGS.md"; exit 1; }
echo "   DAC_RI = $DAC_RI"

echo "=== 10. create DAC-protected AE sui-dac-ae (acpi=restrictive, daci=sui-dac) ==="
# The creating originator is deliberately "Csui-dac-ae", NOT admin:admin.
#
# AEController assigns the AE-ID like this:
#     if (request.getFrom().startsWith("C")) assignAeiC = false;
#     ...
#     aeEntity.setAeid(assignAeiC ? "C"+AE.toUpperCase()+generatedId   // random
#                                 : request.getFrom());                // verbatim
#     aeEntity.setResourceID("/" + Constants.CSE_ID + "/" + aeEntity.getAeid());
#
# Creating as admin:admin therefore yields a FRESH RANDOM ri on every CSE boot,
# while creating as "Csui-dac-ae" pins it to the stable "/in-cse/Csui-dac-ae".
# That matters because DynamicAuthorizationSelector hands the DAS the
# NON-hierarchical ri as targetedResourceID, and that exact string is the
# on-chain policy / CapToken key. A random ri would need a fresh Sui
# transaction after every reboot; the deterministic one is provisioned once.
#
# A "C"-prefixed originator also skips the create-time permission check in
# AEController, so this CREATE succeeds against the restrictive ACP.
DAC_AE_RI="/in-cse/Csui-dac-ae"
ssh_n "curl -s -o /dev/null -w '   DAC-AE: HTTP %{http_code}\n' -X POST '$BASE/~/in-cse/in-name' -H 'X-M2M-Origin: Csui-dac-ae' -H 'X-M2M-RI: dae1' -H 'Content-Type: application/json;ty=2' -d '{\"m2m:ae\":{\"rn\":\"sui-dac-ae\",\"api\":\"N.sui-dac.0001\",\"rr\":false,\"acpi\":[\"$ACP_DAC\"],\"daci\":[\"$DAC_RI\"]}}'"

echo "   confirm the ri is the deterministic one ($DAC_AE_RI):"
ssh_n "curl -s '$BASE/~/in-cse/in-name/sui-dac-ae' -H 'X-M2M-Origin: $ORIG' -H 'Accept: application/json'"   | python3 -c 'import sys,json
try:
    ri = json.load(sys.stdin)["m2m:ae"]["ri"]
    print("   ri =", ri, "(OK)" if ri == "/in-cse/Csui-dac-ae" else "(UNEXPECTED - the on-chain policy key must equal this)")
except Exception as e: print("   could not read ri:", e)'

echo "   verify daci actually persisted (AEController must have stored it):"
ssh_n "curl -s '$BASE/~/in-cse/in-name/sui-dac-ae' -H 'X-M2M-Origin: $ORIG' -H 'Accept: application/json'" \
  | python3 -c 'import sys,json
try:
    ae = json.load(sys.stdin)["m2m:ae"]
    print("   daci =", ae.get("daci"), " acpi =", ae.get("acpi"))
except Exception as e: print("   could not read sui-dac-ae:", e)'

echo "=== 11. DAC PROBE: ordinary RETRIEVE, no special headers, originator=$DAC_ORIG ==="
echo "    GET /~/in-cse/in-name/sui-dac-ae   (expect the CSE to consult the Sui DAS)"
ssh_n "curl -s -o /dev/null -w '   PROBE: HTTP %{http_code}\n' '$BASE/~/in-cse/in-name/sui-dac-ae' -H 'X-M2M-Origin: $DAC_ORIG' -H 'X-M2M-RI: dacprobe' -H 'Accept: application/json'"
sleep 3
echo "   --- DAS consulted? (look for 'Sui DAC consult' = the in-JVM production path) ---"
ssh_n "docker logs --since 20s om2m-active 2>&1 | grep -iE 'Sui DAC consult|Sending notification to IPE|Sui GRANT|Sui DENY|no sui mapping' | tail -6"
echo ""
echo "# Part B done. Interpretation:"
echo "#   'Sui DAC consult: ...'                              -> C2 CONFIRMED (native DAC path live)"
echo "#   PROBE HTTP 200 + 'Sui GRANT'                        -> on-chain authorization of an ordinary request"
echo "#   PROBE HTTP 403 + 'Sui DENY'                         -> DAC path live, chain denied (also confirms C2)"
echo "#   PROBE HTTP 403 and NO Sui log line at all           -> DAC never consulted; C2 REFUTED on this build"
