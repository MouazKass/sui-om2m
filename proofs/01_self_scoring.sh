#!/usr/bin/env bash
# CONCEPT 1 - SELF-SCORING PREVENTION (TR2). A node cannot raise its own trust.
# v8: IDs from deploy/v8/env.v8.sh via proofs/lib_v8.sh.
PROOF_ID=01; source "$(dirname "$0")/lib_v8.sh"
banner "CONCEPT 1 - SELF-SCORING PREVENTION"

echo "=== PART A: a foreign module calling the unguarded primitive cannot compile ==="
echo
echo "\$ cat selfscore_attack_test/sources/attack.move   (the bypass attempt)"
sed -n '/module selfscore_attack/,/^}/p' selfscore_attack_test/sources/attack.move | sed 's/^/    /'
echo
echo "\$ sui move build   (in WSL, on a scratch copy of move/ + selfscore_attack_test/)"
WREPO=$(sed 's#^/\([a-z]\)/#/mnt/\1/#' <<<"$REPO")
BUILD=$(wsl_run "set -e; d=\$(mktemp -d); cp -r '$WREPO/move' '$WREPO/selfscore_attack_test' \$d/; rm -rf \$d/move/build; cd \$d/selfscore_attack_test && sui move build 2>&1 || true; rm -rf \$d")
sed $'s/\x1b\[[0-9;]*m//g' <<<"$BUILD" | grep -B2 -A8 -E "trust::increase|restricted visibility|E04001" | head -14 | sed 's/^/    /'
if grep -qE "restricted visibility|E04001" <<<"$BUILD" && grep -q "increase" <<<"$BUILD"; then
  echo "    [PASS] the bypass module does not compile (trust::increase is public(package))"; PROOF_PASS=$((${PROOF_PASS:-0}+1))
else
  echo "    [FAIL] expected a visibility error on trust::increase"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1))
fi
echo

echo "=== PART B: a node signing a call to raise ITS OWN score is aborted on-chain ==="
echo "    rpi3, using its own key and its own AdminCap, targets its own address."
echo
node_call rpi3 trust increase_guarded "$ADMINCAP_RPI3" "$TRUST_REG" "$RPI3" 5 0x6
expect "rpi3 self-raise rejected (E_SELF_SCORING)" abort 4
echo
hr
echo "WHAT THIS SHOWS: no adversary-published module can reach the unguarded primitive"
echo "(Part A), and the guarded path aborts when the signer is the node being scored"
echo "(Part B, code 4). The aborted transaction is on-chain under the digest above."
summary
