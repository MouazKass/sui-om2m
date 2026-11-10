#!/usr/bin/env bash
# CONCEPT 9 - ADMIN CAP REVOCATION (TR7, A1/A2/A8).
# An AdminCap can be revoked on-chain; once revoked it can neither write a
# score nor mint a replacement cap for itself (v8 / A2: the GRANTING cap is
# validated too, so revoked authority cannot be laundered into a fresh cap).
#
# v8 change: the proof no longer revokes a production cap (the v7 script
# revoked rpi2's real cap and left it broken). It grants rpi2 a THROWAWAY cap,
# revokes that, attacks with it, and has rpi2 burn it at the end.
# v9 change: the grant and the revoke are 3-of-5 council decisions (no single
# cap, the publisher's included, can grant or revoke another cap any more), and
# the proof also shows that the old single-cap path is closed (E_GOVERNED).
PROOF_ID=09; source "$(dirname "$0")/lib_v8.sh"
banner "CONCEPT 9 - ADMIN CAP REVOCATION"
valid() { dev_inspect trust is_cap_valid "$TRUST_REG" "$1"; }

echo "=== SETUP: the council grants rpi2 a throwaway AdminCap (3-of-5, registered as valid) ==="
council_do grant-throwaway trust-grant-admin "$RPI2"
expect "council grant executed" success
sleep 3
X=$(created_object "$LAST_DIGEST" "::trust::AdminCap")
[ -n "$X" ] || { echo "    FATAL: no AdminCap created by $LAST_DIGEST"; exit 1; }
echo "    throwaway cap: $X (owner rpi2)"
sleep 3
V0=$(valid "$X"); echo "    is_cap_valid before: $V0"
echo

echo "=== v9: NO SINGLE CAP CAN REVOKE ANOTHER ONE (the pre-council path is closed) ==="
node_call rpi1 trust revoke_admin "$ADMINCAP_RPI1" "$TRUST_REG" "$X"
expect "rpi1 alone revoking rpi2's cap rejected (E_GOVERNED)" abort 8
echo

echo "=== THE OPERATION: the council revokes it on-chain (3-of-5) ==="
council_do revoke-throwaway trust-revoke-admin "$X"
expect "council revoke executed" success
sleep 3
V1=$(valid "$X"); echo "    is_cap_valid after:  $V1"
[ "${V0,,}" = true ] && [ "${V1,,}" = false ] && { echo "    [PASS] valid -> revoked"; PROOF_PASS=$((${PROOF_PASS:-0}+1)); } \
  || { echo "    [FAIL] validity $V0 -> $V1"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1)); }
echo

echo "=== CONSEQUENCE 1: the revoked cap can no longer write a score ==="
node_call rpi2 trust increase_guarded "$X" "$TRUST_REG" "$RPI1" 1 0x6
expect "score write with the revoked cap rejected (E_CAP_REVOKED)" abort 5
echo
# Under v9 the single-cap grant / add_node paths are closed for EVERY cap
# (E_GOVERNED, checked first); v8's A1/A2 validity checks behind them are still
# covered by move/tests (trust_revocation_tests, quorum_tests).
echo "=== CONSEQUENCE 2: it cannot mint itself a fresh cap ==="
node_call rpi2 trust grant_admin_registered "$X" "$TRUST_REG" "$RPI2"
expect "grant from the revoked cap rejected (E_GOVERNED: grants are council-only)" abort 8
echo
echo "=== CONSEQUENCE 3: it cannot register a node ==="
node_call rpi2 trust add_node "$X" "$TRUST_REG" 0x000000000000000000000000000000000000000000000000000000000000dead 100 0x6
expect "add_node with the revoked cap rejected (E_GOVERNED: admission is council-only)" abort 8
echo
echo "=== CLEANUP: rpi2 burns the throwaway cap ==="
node_call rpi2 trust burn_admin "$TRUST_REG" "$X"
expect "throwaway cap burned" success
echo "    rpi2's production cap is untouched: is_cap_valid(\$ADMINCAP_RPI2) = $(valid "$ADMINCAP_RPI2")"
echo
hr
echo "WHAT THIS SHOWS: an AdminCap's validity is on-chain state. Granting and revoking a"
echo "cap is a 3-of-5 council decision - a single cap holder is refused (code 8). Once"
echo "revoked, the cap can write no score (code 5), mint no replacement and register no"
echo "node. Admin authority is revocable, collectively, and stays revoked."
summary
