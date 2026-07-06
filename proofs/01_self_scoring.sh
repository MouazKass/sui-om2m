#!/usr/bin/env bash
# CONCEPT 1 - SELF-SCORING PREVENTION (TR2). A node cannot raise its own trust.
cd "$(dirname "$0")/.." && source scripts/env.sh
echo
echo "################################################################################"
echo "#  CONCEPT 1 - SELF-SCORING PREVENTION"
echo "################################################################################"
echo
echo "=== PART A: a foreign module calling the unguarded primitive cannot compile ==="
echo
echo "\$ cat selfscore_attack_test/sources/attack.move   (the bypass attempt)"
sed -n '/module selfscore_attack/,/^}/p' selfscore_attack_test/sources/attack.move | sed 's/^/    /'
echo
echo "\$ cd selfscore_attack_test && sui move build"
echo
( cd selfscore_attack_test && sui move build 2>&1 | sed 's/^/    /' | grep -A8 "E04001\|restricted visibility\|Compilation error" )
echo
echo "--> The bypass module cannot be built. No adversary-published module can reach"
echo "    the unguarded primitive."
echo
echo "=== PART B: a node signing a call to raise ITS OWN score is aborted on-chain ==="
echo "    rpi3, using its own key + its own AdminCap, tries to raise rpi3's score."
echo
echo "\$ docker exec om2m-active sui client call \\"
echo "    --package $PKG_V7 \\"
echo "    --module trust --function increase_guarded \\"
echo "    --args $ADMINCAP_RPI3 \\"
echo "           $TRUST_REG \\"
echo "           $RPI3 5 0x6 \\"
echo "    --gas-budget 50000000"
echo
sshpass -p user ssh user@10.25.96.203 \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module trust --function increase_guarded \
     --args $ADMINCAP_RPI3 $TRUST_REG $RPI3 5 0x6 \
     --gas-budget 50000000 2>&1 | grep -iE 'MoveAbort|Success|abort' | head -3 | sed 's/^/    /'"
echo
echo "    abort code 4 = E_SELF_SCORING (sender == node, so the guard fires)"
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: self-scoring is impossible for any caller - a foreign module"
echo "cannot compile a bypass (Part A), and the guarded path aborts when the signer is"
echo "the node being scored (Part B, code 4)."
echo "--------------------------------------------------------------------------------"
