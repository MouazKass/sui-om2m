#!/usr/bin/env bash
# CONCEPT 9 - ADMIN CAP REVOCATION (TR7, A1/A2/A8).
# An AdminCap can be revoked on-chain; once revoked it can neither write a
# score nor mint a replacement cap for itself (v8 / A2: the GRANTING cap is
# validated too, so revoked authority cannot be laundered into a fresh cap).
#
# v8 change: the proof no longer revokes a production cap (the v7 script
# revoked rpi2's real cap and left it broken). It grants rpi2 a THROWAWAY cap,
# revokes that, attacks with it, and has rpi2 burn it at the end.
PROOF_ID=09; source "$(dirname "$0")/lib_v8.sh"
banner "CONCEPT 9 - ADMIN CAP REVOCATION"
valid() { dev_inspect trust is_cap_valid "$TRUST_REG" "$1"; }

echo "=== SETUP: the publisher grants rpi2 a throwaway AdminCap (registered as valid) ==="
pub_call trust grant_admin_registered "$TR_ADMIN_CAP" "$TRUST_REG" "$RPI2"
expect "throwaway cap granted" success
X=$(python -c "
import sys,json; t=sys.stdin.read(); d=json.loads(t[t.find('{'):])
print(next(c['objectId'] for c in d['objectChanges'] if c.get('type')=='created' and c.get('objectType','').endswith('::trust::AdminCap')))" <<<"$LAST_OUT")
echo "    throwaway cap: $X (owner rpi2)"
sleep 3
V0=$(valid "$X"); echo "    is_cap_valid before: $V0"
echo

echo "=== THE OPERATION: revoke it on-chain ==="
pub_call trust revoke_admin "$TR_ADMIN_CAP" "$TRUST_REG" "$X"
expect "revoke_admin" success
sleep 3
V1=$(valid "$X"); echo "    is_cap_valid after:  $V1"
[ "${V0,,}" = true ] && [ "${V1,,}" = false ] && { echo "    [PASS] valid -> revoked"; PROOF_PASS=$((${PROOF_PASS:-0}+1)); } \
  || { echo "    [FAIL] validity $V0 -> $V1"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1)); }
echo

echo "=== CONSEQUENCE 1: the revoked cap can no longer write a score ==="
node_call rpi2 trust increase_guarded "$X" "$TRUST_REG" "$RPI1" 1 0x6
expect "score write with the revoked cap rejected (E_CAP_REVOKED)" abort 5
echo
echo "=== CONSEQUENCE 2 (v8 / A2): it cannot mint itself a fresh, valid cap ==="
node_call rpi2 trust grant_admin_registered "$X" "$TRUST_REG" "$RPI2"
expect "grant from a revoked cap rejected (E_CAP_REVOKED)" abort 5
echo
echo "=== CONSEQUENCE 3 (v8 / A1): it cannot register a node ==="
node_call rpi2 trust add_node "$X" "$TRUST_REG" 0x000000000000000000000000000000000000000000000000000000000000dead 100 0x6
expect "add_node with a revoked cap rejected (E_CAP_REVOKED)" abort 5
echo
echo "=== CLEANUP: rpi2 burns the throwaway cap ==="
node_call rpi2 trust burn_admin "$TRUST_REG" "$X"
expect "throwaway cap burned" success
echo "    rpi2's production cap is untouched: is_cap_valid(\$ADMINCAP_RPI2) = $(valid "$ADMINCAP_RPI2")"
echo
hr
echo "WHAT THIS SHOWS: an AdminCap's validity is on-chain state; revoke_admin removes it"
echo "from the valid set; afterwards the cap can write no score (code 5), mint no"
echo "replacement and register no node. Admin authority is revocable and stays revoked."
summary
