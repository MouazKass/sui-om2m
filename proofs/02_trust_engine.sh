#!/usr/bin/env bash
# CONCEPT 2 - TRUST ENGINE / PEER SCORING (TR1,TR3-TR6). Peers score peers; only
# an AdminCap holder can write a score; scores live on-chain.
cd "$(dirname "$0")/.." && source scripts/env.sh
echo
echo "################################################################################"
echo "#  CONCEPT 2 - TRUST ENGINE / PEER SCORING"
echo "################################################################################"
echo
echo "=== rpi2's on-chain score BEFORE ==="
echo
echo "\$ sui client call --package \$PKG_V7 --module trust --function score_of \\"
echo "    --args $TRUST_REG $RPI2 0x6   (dev-inspect read)"
echo
BEFORE=$(sui client call --package "$PKG_V7" --module trust --function score_of \
    --args "$TRUST_REG" "$RPI2" 0x6 --dev-inspect 2>/dev/null \
    | grep -iE "return|value" | head -1)
echo "    rpi2 score before: ${BEFORE:-<read via object below>}"
sui client object "$TRUST_REG" --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('    (TrustRegistry object:', d.get('objectId','')[:20]+'...)')" 2>/dev/null
echo
echo "=== THE OPERATION: rpi1 raises rpi2's score (sender=rpi1, node=rpi2: valid) ==="
echo
echo "\$ docker exec om2m-active sui client call \\"
echo "    --package $PKG_V7 \\"
echo "    --module trust --function increase_guarded \\"
echo "    --args $ADMINCAP_RPI1 \\"
echo "           $TRUST_REG \\"
echo "           $RPI2 3 0x6 \\"
echo "    --gas-budget 50000000"
echo
sshpass -p user ssh user@10.25.96.200 \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module trust --function increase_guarded \
     --args $ADMINCAP_RPI1 $TRUST_REG $RPI2 3 0x6 \
     --gas-budget 50000000 2>&1 | grep -iE 'Transaction Digest|Status|MoveAbort' | head -3 | sed 's/^/    /'"
echo
echo "=== rpi2's on-chain score AFTER ==="
echo
AFTER=$(sui client call --package "$PKG_V7" --module trust --function score_of \
    --args "$TRUST_REG" "$RPI2" 0x6 --dev-inspect 2>/dev/null \
    | grep -iE "return|value" | head -1)
echo "    rpi2 score:  before ${BEFORE:-?}  ->  after ${AFTER:-?}"
echo
echo "=== A CALLER WITHOUT THE CAP CANNOT SCORE ==="
echo "    The publisher tries to use rpi3's AdminCap, which it does not own."
echo
echo "\$ sui client call --package \$PKG_V7 --module trust --function increase_guarded \\"
echo "    --args $ADMINCAP_RPI3 $TRUST_REG $RPI2 3 0x6 --gas-budget 50000000"
echo
sui client call --package "$PKG_V7" --module trust --function increase_guarded \
    --args "$ADMINCAP_RPI3" "$TRUST_REG" "$RPI2" 3 0x6 \
    --gas-budget 50000000 2>&1 | grep -iE "not signed by|owned by|InvalidArgument" | head -1 | sed 's/^/    /'
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: scores are on-chain state; a peer can raise a DIFFERENT peer's"
echo "score (digest above, before->after); a caller cannot use a capability it does"
echo "not own, so scoring is gated by capability ownership."
echo "--------------------------------------------------------------------------------"
