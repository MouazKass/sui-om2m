#!/usr/bin/env bash
# provision-das.sh - (re)create the in-memory OM2M resources the Sui DAS needs.
#
# Installed at /usr/local/bin/provision-das.sh on every node. Runs at boot via
# sui-das-provision.service, and from das-watchdog.sh whenever a resource has
# gone missing. OM2M's resource DB is in-memory, so everything here is lost on
# every container restart. Every step is idempotent (201 created / 409 exists).
#
# v8 changes compared with the v7 script:
#
#  1. Csensor-001 is NO LONGER granted acop 63 on acp_admin.
#     DynamicAuthorizationConsultation is consulted only when the static ACP
#     check FAILS (Controller.checkPermissions). That static grant let
#     Csensor-001 straight through on every resource carrying acp_admin, so the
#     chain was never asked. Nothing depends on it: the ESP32 interworking
#     bridge writes as admin:admin (/etc/om2m-ipe-bridge/bridge.conf), and the
#     NOTIFY proof scripts send as admin:admin too.
#
#  2. Part B: the C2 wiring, so ordinary requests reach the DAS.
#       acp_sui_dac  ACP granting only admin; any other originator fails the
#                    static check and falls through to the DAS
#       sui-dac      <dynamicAuthorizationConsultation> (ty=34) -> sui-das AE
#       sui-dac-ae   the protected resource. An <AE>, because a <container>
#                    can never be DAS-protected: ContainerController calls
#                    checkACP only, never checkPermissions. Created as
#                    originator Csui-dac-ae so its ri is the stable
#                    /in-cse/Csui-dac-ae, which is the on-chain policy and
#                    token key.
set -uo pipefail
BASE=http://127.0.0.1:8282
ORIG=admin:admin
J='Accept: application/json'
log() { echo "[provision-das $(date +%H:%M:%S)] $*"; }
ri() { python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(list(d.values())[0]["ri"])
except Exception: print("")' 2>/dev/null; }
get_ri() { curl -s "$BASE/~/in-cse/in-name/$1" -H "X-M2M-Origin: $ORIG" -H "$J" | ri; }

# Wait up to 180s for acp_admin (created late in OM2M startup).
ACP=""
for i in $(seq 1 90); do
  ACP=$(get_ri acp_admin)
  [ -n "$ACP" ] && break
  sleep 2
done
[ -z "$ACP" ] && { log "acp_admin never appeared after 180s; aborting"; exit 0; }
log "acp_admin ready: $ACP"

# ---- Part A: DAS AE + legacy container --------------------------------------
# acp_admin grants admin only (see change 1 in the header).
curl -s -o /dev/null -X PUT "$BASE/~$ACP" -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: u' \
  -H 'Content-Type: application/json' \
  -d '{"m2m:acp":{"pv":{"acr":[{"acor":["admin:admin","/in-cse"],"acop":63}]}}}'

ae=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/~/in-cse/in-name" -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: a' \
  -H 'Content-Type: application/json;ty=2' \
  -d "{\"m2m:ae\":{\"rn\":\"sui-das\",\"api\":\"N.sui-das.0001\",\"apn\":\"sui-das\",\"poa\":[\"sui-das\"],\"rr\":true,\"acpi\":[\"$ACP\"]}}")
cnt=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/~/in-cse/in-name" -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: c' \
  -H 'Content-Type: application/json;ty=3' \
  -d "{\"m2m:cnt\":{\"rn\":\"sui-protected-cnt\",\"acpi\":[\"$ACP\"]}}")
log "Part A: sui-das AE=$ae  sui-protected-cnt=$cnt (201 created, 409 present)"

# ---- Part B: C2 DynamicAuthorizationConsultation wiring ---------------------
acpd=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/~/in-cse/in-name" -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: acpd' \
  -H 'Content-Type: application/json;ty=1' \
  -d '{"m2m:acp":{"rn":"acp_sui_dac","pv":{"acr":[{"acor":["admin:admin","/in-cse"],"acop":63}]},"pvs":{"acr":[{"acor":["admin:admin","/in-cse"],"acop":63}]}}}')
ACP_DAC=$(get_ri acp_sui_dac)
DAS_AE_RI=$(get_ri sui-das)
[ -z "$ACP_DAC" ] || [ -z "$DAS_AE_RI" ] && { log "Part B: missing acp_sui_dac ($ACP_DAC) or sui-das ($DAS_AE_RI); aborting"; exit 0; }

# dap MUST be the DAS AE's ri (Redirector resolves dap by resourceID); dae is mandatory.
dac=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/~/in-cse/in-name" -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: dac1' \
  -H 'Content-Type: application/json;ty=34' \
  -d "{\"m2m:dac\":{\"rn\":\"sui-dac\",\"dae\":true,\"dap\":[\"$DAS_AE_RI\"],\"acpi\":[\"$ACP\"]}}")
DAC_RI=$(get_ri sui-dac)
[ -z "$DAC_RI" ] && { log "Part B: sui-dac (ty=34) not created (HTTP $dac); aborting"; exit 0; }

daeae=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/~/in-cse/in-name" -H 'X-M2M-Origin: Csui-dac-ae' -H 'X-M2M-RI: dae1' \
  -H 'Content-Type: application/json;ty=2' \
  -d "{\"m2m:ae\":{\"rn\":\"sui-dac-ae\",\"api\":\"N.sui-dac.0001\",\"rr\":false,\"acpi\":[\"$ACP_DAC\"],\"daci\":[\"$DAC_RI\"]}}")
DAC_AE_RI=$(get_ri sui-dac-ae)
log "Part B: acp_sui_dac=$acpd sui-dac=$dac sui-dac-ae=$daeae  ri=$DAC_AE_RI"
[ "$DAC_AE_RI" = "/in-cse/Csui-dac-ae" ] || log "WARNING: sui-dac-ae ri is '$DAC_AE_RI', expected /in-cse/Csui-dac-ae (on-chain policy/token key)"

code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/~/in-cse/in-name/sui-das" -H "X-M2M-Origin: $ORIG")
log "sui-das resource: HTTP $code"
log "provisioning complete"
