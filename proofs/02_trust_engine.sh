#!/usr/bin/env bash
# CONCEPT 2 - TRUST ENGINE / PEER SCORING (TR1,TR3-TR6). Peers score peers via the
# guarded path; the self-scoring guard blocks a node from scoring itself.
cd "$(dirname "$0")/.." && source scripts/env.sh
clean() { sed 's/[│|]//g; s/  */ /g; s/^ *//; /^$/d; s/^/    /'; }
echo
echo "################################################################################"
echo "#  CONCEPT 2 - TRUST ENGINE / PEER SCORING"
echo "################################################################################"
echo
echo "=== A PEER RAISES ANOTHER PEER'S SCORE (valid: sender=rpi1, target=rpi2) ==="
echo "    rpi1 uses its own AdminCap to raise rpi2's trust via increase_guarded."
echo "    The guard permits this because the signer (rpi1) != the target (rpi2)."
echo
echo "\$ docker exec om2m-active sui client call \\"
echo "    --package $PKG_V7 --module trust --function increase_guarded \\"
echo "    --args <rpi1_admincap> $TRUST_REG $RPI2 3 0x6   (signed by rpi1)"
echo
sshpass -p user ssh user@10.25.96.200 \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module trust --function increase_guarded \
     --args $ADMINCAP_RPI1 $TRUST_REG $RPI2 3 0x6 \
     --gas-budget 50000000 2>&1 | grep -iE 'Transaction Digest|Status:|ScoreChanged|new_score|MoveAbort' | head -5" | clean
echo
echo "=== THE SAME NODE CANNOT RAISE ITS OWN SCORE (self-scoring guard) ==="
echo "    rpi2 signs a call to raise rpi2's own score. signer == target, so the"
echo "    guard aborts with E_SELF_SCORING (code 4)."
echo
echo "\$ docker exec om2m-active sui client call \\"
echo "    --package $PKG_V7 --module trust --function increase_guarded \\"
echo "    --args <rpi2_admincap> $TRUST_REG $RPI2 3 0x6   (signed by rpi2)"
echo
SELF=$(sshpass -p user ssh user@10.25.96.201 \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module trust --function increase_guarded \
     --args $ADMINCAP_RPI2 $TRUST_REG $RPI2 3 0x6 \
     --gas-budget 50000000 2>&1")
echo "$SELF" | grep -iE "aborted within|with code [0-9]|Error executing" | clean
CODE=$(echo "$SELF" | grep -oE 'with code [0-9]+' | grep -oE '[0-9]+' | head -1)
[ "$CODE" = "4" ] && echo "    (abort code 4 = E_SELF_SCORING - a node cannot score itself)"
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: trust scores are written on-chain through the guarded path;"
echo "a peer can raise a DIFFERENT peer's score (Success, digest above), but the same"
echo "node signing to raise its OWN score is rejected (code 4). Peer-driven scoring"
echo "with a structural self-scoring guard."
echo "--------------------------------------------------------------------------------"
