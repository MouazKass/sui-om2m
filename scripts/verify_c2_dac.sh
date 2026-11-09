#!/usr/bin/env bash
#
# verify_c2_dac.sh - decide, on real hardware, whether OM2M consults the Sui DAS
#                    on an ORDINARY oneM2M request (claim "C2").
#
# This script does not assume the answer. It runs four probes whose combined
# outcome distinguishes two mutually exclusive hypotheses:
#
#   H1  (C2 holds)  The CSE natively routes an access-denied ordinary request
#                   to the Sui DAS through <dynamicAuthorizationConsultation>.
#   H0  (C2 fails)  The CSE never consults the DAS; the only working route is
#                   the hand-crafted HTTP NOTIFY used by proofs/*.sh.
#
# Prerequisite: bench/provision_das.sh has been run (including Part B, which
# creates acp_sui_dac / sui-dac / sui-dac-ae), and the on-chain policy +
# CapToken + sui.mappings.properties entries for /in-cse/Csui-dac-ae
# exist (see scripts/bootstrap_testbed.sh).
#
# Usage:  ./verify_c2_dac.sh [node_ip]
#
set -uo pipefail

NODE="${1:-10.25.96.203}"
PW="${PW:-user}"
ADMIN="${ADMIN:-admin:admin}"
PROBE="${PROBE:-Csensor-001}"     # originator that acp_sui_dac does NOT list
BASE=http://127.0.0.1:8282
CONTAINER="om2m-active"

ssh_n() { sshpass -p "$PW" ssh -o StrictHostKeyChecking=no user@"$NODE" "$@"; }

# Run one probe: $1 = label, $2 = path, $3 = originator.
# Prints the HTTP status and every Sui/IPE log line the request produced.
probe() {
  local label="$1" path="$2" orig="$3"
  echo "---------------------------------------------------------------"
  echo "PROBE: $label"
  echo "  GET $path     X-M2M-Origin: $orig   (no X-M2M-Operation header)"
  ssh_n "curl -s -o /dev/null -w '  HTTP %{http_code}\n' '$BASE/~$path' \
           -H 'X-M2M-Origin: $orig' -H 'X-M2M-RI: v-$RANDOM' -H 'Accept: application/json'"
  sleep 3
  echo "  log lines:"
  ssh_n "docker logs --since 12s $CONTAINER 2>&1 \
          | grep -iE 'Sui DAC consult|Sending notification to IPE|Sui GRANT|Sui DENY|No Sui mapping|authorize ' \
          | tail -8 | sed 's/^/    /'" || true
  echo "  (no lines above = nothing in the DAC/Sui path fired)"
}

echo "###############################################################"
echo "# C2 verification   node=$NODE   $(date -u +%FT%TZ)"
echo "###############################################################"

echo
echo "=== 0. preconditions ==="
ssh_n "curl -s -o /dev/null -w '  CSE: HTTP %{http_code}\n' '$BASE/~/in-cse' -H 'X-M2M-Origin: $ADMIN'"
for r in sui-das sui-dac sui-dac-ae acp_sui_dac; do
  ssh_n "curl -s -o /dev/null -w \"  $r: HTTP %{http_code}\n\" '$BASE/~/in-cse/in-name/$r' -H 'X-M2M-Origin: $ADMIN'"
done
echo "  (sui-dac must be 200. A 404 here means this OM2M build rejected ty=34"
echo "   and C2 is not available on it - stop and read C2_FINDINGS.md.)"

echo
echo "  sui-dac-ae attributes as stored by the CSE:"
ssh_n "curl -s '$BASE/~/in-cse/in-name/sui-dac-ae' -H 'X-M2M-Origin: $ADMIN' -H 'Accept: application/json'" \
  | python3 -c 'import sys,json
try:
    ae=json.load(sys.stdin)["m2m:ae"]
    print("    acpi =",ae.get("acpi"))
    print("    daci =",ae.get("daci"))
    if not ae.get("daci"):
        print("    !! daci is EMPTY -> AEController did not persist the link;")
        print("       the DAC can never be consulted. C2 REFUTED on this build.")
except Exception as e:
    print("    could not parse sui-dac-ae:",e)'

# ---------------------------------------------------------------------------
# PROBE 1 - the decisive one.
#   H1 predicts: a 'Sui DAC consult' / 'Sending notification to IPE' line, and
#                HTTP 200 (chain granted) or 403 (chain denied).
#   H0 predicts: HTTP 403 with NO Sui or IPE line whatsoever.
# ---------------------------------------------------------------------------
echo
probe "1. DAC-protected AE, unprivileged originator  [DECISIVE]" \
      "/in-cse/in-name/sui-dac-ae" "$PROBE"

# ---------------------------------------------------------------------------
# PROBE 2 - control for "DAC is consulted only after the static check fails".
#   admin:admin IS listed in acp_sui_dac, so the static check succeeds and
#   Controller.checkPermissions returns before touching the DAC.
#   Expect HTTP 200 and NO Sui log line. A Sui line here would mean the
#   consultation is not gated on static failure, contradicting the source.
# ---------------------------------------------------------------------------
echo
probe "2. DAC-protected AE, admin originator  [control: static grant wins]" \
      "/in-cse/in-name/sui-dac-ae" "$ADMIN"

# ---------------------------------------------------------------------------
# PROBE 3 - control for the container finding.
#   ContainerController calls the plain checkACP and never checkPermissions,
#   so a <container> must NOT reach the DAS even with a DAC on its parent.
#   Expect HTTP 403 and NO Sui log line. A Sui line here would falsify the
#   container claim in C2_FINDINGS.md.
# ---------------------------------------------------------------------------
echo
probe "3. plain container, unprivileged originator  [control: cnt is not DAC-enforced]" \
      "/in-cse/in-name/sui-protected-cnt" "$PROBE"

# ---------------------------------------------------------------------------
# PROBE 4 - the legacy synthetic path must keep working (proofs depend on it).
# ---------------------------------------------------------------------------
echo
echo "---------------------------------------------------------------"
echo "PROBE: 4. legacy HTTP NOTIFY path  [regression guard for proofs/*.sh]"
ssh_n "curl -s -o /dev/null -w '  HTTP %{http_code}\n' -X POST '$BASE/~/in-cse/in-name/sui-das' \
        -H 'X-M2M-Origin: $ADMIN' -H 'X-M2M-RI: v-notify' -H 'X-M2M-Operation: 5' \
        -H 'Content-Type: application/json' \
        -d '{\"m2m:sec\":{\"sit\":1,\"dreq\":{\"or\":\"$ADMIN\",\"op\":1,\"rid\":\"/in-cse/in-name/sui-protected-cnt\",\"rty\":3}}}'"
sleep 3
ssh_n "docker logs --since 12s $CONTAINER 2>&1 | grep -iE 'Sui GRANT|Sui DENY|No Sui mapping' | tail -3 | sed 's/^/    /'" || true

cat <<'VERDICT'

###############################################################
# HOW TO READ THIS
###############################################################

C2 CONFIRMED (H1) if and only if PROBE 1 produced at least one of:
    Sui DAC consult: originator=Csensor-001 resource=/in-cse/Csui-dac-ae op=2
    Sending notification to IPE: sui-das
    Sui GRANT originator=Csensor-001 resource=/in-cse/Csui-dac-ae ...
    Sui DENY  originator=Csensor-001 resource=/in-cse/Csui-dac-ae ...

  The decisive token is the literal string "Sui DAC consult". SuiDasService
  emits it only when request.getContent() is a typed SecurityInfo object, which
  can only happen on the in-JVM route taken by DynamicAuthorizationSelector ->
  Redirector.retargetNotify -> IpeSelector. An external HTTP NOTIFY always
  arrives as a JSON String and logs "Sui NOTIFY consult" instead, so the two
  routes can never be confused in the log.
  PROBE 1 HTTP 200 means the chain GRANTED an ordinary request - the strongest
  possible evidence. HTTP 403 together with a 'Sui DENY' line is equally good
  evidence that the hook fired; it just means the chain said no (check the
  on-chain policy / CapToken / sui.mappings.properties for sui-dac-ae).

C2 REFUTED (H0) if PROBE 1 returned 403 (or 200) with NO Sui and NO IPE line.
  In that case the only working route really is the synthetic NOTIFY of
  PROBE 4, and the paper must say so. See C2_FINDINGS.md, "If the probe fails".

EXPECTED CONTROLS (these should hold under either hypothesis):
  PROBE 2 -> HTTP 200, no Sui line   (static grant short-circuits the DAC)
  PROBE 3 -> HTTP 403, no Sui line   (containers are not DAC-enforced)
  PROBE 4 -> HTTP 200 + Sui GRANT/DENY (legacy path intact)

If PROBE 2 or PROBE 3 emits a Sui line, a documented assumption is wrong -
record it, because it changes what the paper may claim.
VERDICT
