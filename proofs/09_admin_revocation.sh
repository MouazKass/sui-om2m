#!/usr/bin/env bash
# CONCEPT 9 - ADMIN CAP REVOCATION (TR7). An AdminCap can be revoked on-chain;
# once revoked it is no longer valid and cannot write scores.
cd "$(dirname "$0")/.." && source scripts/env.sh

# We revoke rpi2's admin cap as the demonstration (publisher holds the authority
# AdminCap and the registry). Adjust TARGET_CAP if you prefer a throwaway cap.
TARGET_CAP=$ADMINCAP_RPI2

is_valid() {
  sui client call --package "$PKG_V7" --module trust --function is_cap_valid \
    --args "$TRUST_REG" "$1" --dev-inspect 2>/dev/null \
    | grep -iE "return|value|true|false" | head -1
}

echo
echo "################################################################################"
echo "#  CONCEPT 9 - ADMIN CAP REVOCATION (TR7)"
echo "################################################################################"
echo
echo "    Target AdminCap: $TARGET_CAP"
echo
echo "=== VALIDITY BEFORE: the cap is registered as valid ==="
echo
echo "\$ sui client call --package \$PKG_V7 --module trust --function is_cap_valid \\"
echo "    --args $TRUST_REG $TARGET_CAP   (dev-inspect read)"
echo
echo "    is_cap_valid before: $(is_valid "$TARGET_CAP")"
echo
echo "=== THE OPERATION: revoke the AdminCap on-chain ==="
echo
echo "\$ sui client call \\"
echo "    --package $PKG_V7 \\"
echo "    --module trust --function revoke_admin \\"
echo "    --args $TR_ADMIN_CAP \\"
echo "           $TRUST_REG \\"
echo "           $TARGET_CAP \\"
echo "    --gas-budget 50000000"
echo
sui client call --package "$PKG_V7" --module trust --function revoke_admin \
    --args "$TR_ADMIN_CAP" "$TRUST_REG" "$TARGET_CAP" \
    --gas-budget 50000000 2>&1 | grep -iE "Transaction Digest|Status|MoveAbort" | head -3 | sed 's/^/    /'
sleep 3
echo
echo "=== VALIDITY AFTER: the cap is no longer in the valid set ==="
echo
echo "    is_cap_valid after:  $(is_valid "$TARGET_CAP")"
echo
echo "=== CONSEQUENCE: the revoked cap can no longer write a score ==="
echo "    rpi2 tries to score rpi1 using its now-revoked cap."
echo
sshpass -p user ssh user@10.25.96.201 \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module trust --function increase_guarded \
     --args $TARGET_CAP $TRUST_REG $RPI1 3 0x6 \
     --gas-budget 50000000 2>&1 | grep -iE 'MoveAbort|abort|Status' | head -3 | sed 's/^/    /'"
echo
echo "    abort code 5 = E_CAP_REVOKED (assert_cap_valid rejects the revoked cap)"
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: an AdminCap's validity is on-chain state; revoke_admin removes"
echo "it from the valid set (before->after), and a subsequent score write with the"
echo "revoked cap is rejected (code 5). Admin authority is revocable."
echo "--------------------------------------------------------------------------------"
echo
echo "NOTE: this revokes rpi2's real admin cap. To restore it afterwards, re-grant:"
echo "  sui client call --package \$PKG_V7 --module trust --function grant_admin \\"
echo "    --args \$TR_ADMIN_CAP $RPI2 --gas-budget 50000000"
echo "  (then re-register validity via bootstrap_valid_caps if your flow requires it)"
