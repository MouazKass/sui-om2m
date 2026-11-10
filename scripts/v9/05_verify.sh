#!/usr/bin/env bash
# 05_verify.sh - V9_DESIGN.md phase H: read-only checks, valid at every phase.
#
#   scripts/v9/05_verify.sh
#
# Run in WSL (needs CLI >= 1.83.1; signs nothing). Each check prints PASS, FAIL
# or WAIT (= that phase has not happened yet). The attack checks are dev-inspect
# simulations signed by nobody, so running them costs nothing and changes
# nothing. Exit status is non-zero on any FAIL.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_cli
R1=0xef9c6271d8c6cc9e1d9707a117f876e7a8679509f141879bc05ae7bcffe1d5f9
pass=0; fail=0; wait_=0
P() { echo "PASS  $*"; pass=$((pass+1)); }
F() { echo "FAIL  $*"; fail=$((fail+1)); }
W() { echo "WAIT  $*"; wait_=$((wait_+1)); }
# compare ignoring JSON quotes (u64 view results may come back as strings)
is() { local g="${1//\"/}" w="${2//\"/}"; [ "$g" = "$w" ] && P "$3 ($g)" || F "$3: got '$g', want '$w'"; }

say "C/D: UpgradeCap custody"
owner=$(object_owner "$UPGRADE_CAP")
if [ -n "${UPGRADE_MULTISIG:-}" ]; then
  if [ "$owner" = "AddressOwner:$UPGRADE_MULTISIG" ]; then P "UpgradeCap owned by the 2-of-3 multisig $UPGRADE_MULTISIG"
  elif [ "$owner" = "AddressOwner:$PUBLISHER" ]; then W "multisig recorded, UpgradeCap still with the publisher (01_transfer_upgradecap.sh)"
  else F "UpgradeCap owner is $owner"; fi
else
  [ "$owner" = "AddressOwner:$PUBLISHER" ] && W "no multisig yet; UpgradeCap with the publisher (00_multisig.sh)" || F "UpgradeCap owner is $owner and no multisig is recorded"
fi
ms_bal=""; [ -n "${UPGRADE_MULTISIG:-}" ] && ms_bal=$(sui_balance "$UPGRADE_MULTISIG") && echo "INFO  multisig gas: $ms_bal MIST"

say "E: package"
if [ -z "${PKG_V9:-}" ]; then
  W "not upgraded yet (02_upgrade.sh)"
else
  check_v9_package "$PKG_V9" >/dev/null && P "PKG_V9 $PKG_V9 is on-chain with the quorum module" || F "PKG_V9 is not a v9 package"
  upkg=$("$SUI" client object "$UPGRADE_CAP" --json | python3 -c '
import json,sys
d=json.load(sys.stdin); c=d.get("content") or {}; f=c.get("fields", c)
print(f.get("package",""), f.get("version",""))')
  is "$upkg" "$PKG_V9 2" "UpgradeCap points at v9, version 2"
fi

say "F: plugin config (generated files under deploy/v8/nodes)"
for n in 1 2 3; do
  f="$REPO/deploy/v8/nodes/rpi$n/sui.properties"
  call=$(sed -n 's/^sui.package.id=//p' "$f"); orig=$(sed -n 's/^sui.package.original.id=//p' "$f")
  is "$orig" "$PKG_V8" "rpi$n type-origin id stays v8"
  if [ -n "${PKG_V9:-}" ] && [ "$call" = "$PKG_V9" ]; then P "rpi$n calls v9"
  elif [ "$call" = "$PKG_V8" ]; then W "rpi$n still calls v8 (03_switch_plugin.sh v9)"
  else F "rpi$n sui.package.id=$call"; fi
done
[ -n "${V9_GRANT_VERIFIED:-}" ] && P "v9 calls seen landing from the nodes at $V9_GRANT_VERIFIED" || W "v9 calls from the nodes not verified yet"

say "G: governance"
governed=false
[ -n "${PKG_V9:-}" ] && governed=$(inspect_value "$PKG_V9" trust is_governed "$TRUST_REG")
if [ "$governed" != true ]; then
  W "governance not armed (04_council.sh)"
  # The review's attack is still open on v8; show it so nobody mistakes WAIT for safe.
  r=$(inspect_outcome "$R1" "$PKG_V8" trust revoke_admin "$TRUST_ADMIN_CAP_RPI1" "$TRUST_REG" "$TRUST_ADMIN_CAP_RPI2")
  [ "$r" = success ] && echo "INFO  peer revoke via v8 still SUCCEEDS (simulated): the gap v9 closes is open until phase G" \
                     || echo "INFO  peer revoke via v8 simulated: $r"
else
  [ -n "${COUNCIL:-}" ] && P "TrustRegistry governed by COUNCIL $COUNCIL" || F "governed, but no COUNCIL recorded"
  is "$(inspect_value "$PKG_V9" quorum threshold "$COUNCIL")"    2 "threshold"
  is "$(inspect_value "$PKG_V9" quorum member_count "$COUNCIL")" 3 "member count"
  for v in holds_identity_cap holds_policy_cap holds_issuer_cap; do
    is "$(inspect_value "$PKG_V9" quorum "$v" "$COUNCIL")" true "$v"
  done
  is "$(inspect_value "$PKG_V9" quorum holds_cluster_cap "$COUNCIL" "$CLUSTER")" true "holds_cluster_cap"

  say "H: the review's attack, simulated (nobody signs)"
  is "$(inspect_outcome "$R1" "$PKG_V9" trust revoke_admin "$TRUST_ADMIN_CAP_RPI1" "$TRUST_REG" "$TRUST_ADMIN_CAP_RPI2")" \
     "abort:trust::revoke_admin:8" "rpi1 revoking rpi2's cap via v9 -> E_GOVERNED"
  r=$(inspect_outcome "$R1" "$PKG_V8" trust revoke_admin "$TRUST_ADMIN_CAP_RPI1" "$TRUST_REG" "$TRUST_ADMIN_CAP_RPI2")
  case "$r" in abort:trust::*:5) P "same attack via the old v8 package id -> E_CAP_REVOKED ($r)";; *) F "v8-path attack: $r, want abort code 5";; esac
  is "$(inspect_outcome "$R1" "$PKG_V9" trust revoke_admin "$TRUST_ADMIN_CAP_RPI1" "$TRUST_REG" "$TRUST_ADMIN_CAP_RPI1")" \
     success "self-revocation stays unilateral (simulated only)"
  gv=$(inspect_value "$PKG_V9" trust is_cap_valid "$TRUST_REG" "$TRUST_ADMIN_CAP")
  [ "$gv" = false ] && P "publisher's genesis trust cap revoked (first 2-of-3 action done)" \
                    || W "publisher's genesis trust cap still valid (first governed action, V9_DESIGN.md H)"
fi

echo
echo "result: $pass pass, $fail fail, $wait_ waiting"
[ "$fail" -eq 0 ]
