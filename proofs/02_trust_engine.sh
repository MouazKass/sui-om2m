#!/usr/bin/env bash
# CONCEPT 2 - TRUST ENGINE / PEER SCORING (TR1, TR3-TR6, TR8).
# Peers score peers through the guarded path; a node cannot score itself; and
# (v8, A12) every write is bounded: |delta| <= 15 and >= 60 s between writes
# to the same node. Self-restoring: rpi2's score is put back at the end.
PROOF_ID=02; source "$(dirname "$0")/lib_v8.sh"
banner "CONCEPT 2 - TRUST ENGINE / PEER SCORING"

# A peer write that collides with the live trust engine's own (paced) write to
# the same target is rate-limited (code 7); wait the interval out once and retry.
peer_write() {  # <fn> <delta>
  node_call rpi1 trust "$1" "$ADMINCAP_RPI1" "$TRUST_REG" "$RPI2" "$2" 0x6
  if [ "$LAST_STATUS:$LAST_CODE" = "abort:7" ]; then
    echo "    (rpi2 was written by the live trust engine in the last 60 s; retrying once)"
    sleep 62; node_call rpi1 trust "$1" "$ADMINCAP_RPI1" "$TRUST_REG" "$RPI2" "$2" 0x6
  fi
}

S0=$(score "$RPI2"); echo "    rpi2 effective score before: $S0"; echo

echo "=== A PEER LOWERS ANOTHER PEER'S SCORE (valid: signer rpi1, target rpi2) ==="
peer_write decrease_guarded 3
expect "rpi1 -> rpi2 decrease by 3" success
T1=$(date +%s)
S1=$(score "$RPI2"); echo "    rpi2 effective score after:  $S1"; echo

echo "=== THE TARGET CANNOT RAISE ITS OWN SCORE (self-scoring guard) ==="
node_call rpi2 trust increase_guarded "$ADMINCAP_RPI2" "$TRUST_REG" "$RPI2" 3 0x6
expect "rpi2 self-raise rejected (E_SELF_SCORING)" abort 4
echo

echo "=== v8 / A12: A SINGLE WRITE CANNOT MOVE A SCORE BY MORE THAN 15 ==="
node_call rpi1 trust increase_guarded "$ADMINCAP_RPI1" "$TRUST_REG" "$RPI2" 16 0x6
expect "delta 16 rejected (E_DELTA_TOO_LARGE)" abort 6
echo

echo "=== v8 / A12: A SECOND WRITE TO THE SAME NODE WITHIN 60 s IS REJECTED ==="
node_call rpi1 trust increase_guarded "$ADMINCAP_RPI1" "$TRUST_REG" "$RPI2" 3 0x6
expect "immediate second write rejected (E_RATE_LIMITED)" abort 7
echo

echo "=== RESTORE: after the interval, the same peer write succeeds ==="
wait_rate_limit "$T1"
peer_write increase_guarded 3
expect "rpi1 -> rpi2 increase by 3 after 60 s" success
S2=$(score "$RPI2"); echo "    rpi2 effective score restored: $S2 (started at $S0)"
echo
hr
echo "WHAT THIS SHOWS: scores are written on-chain through the guarded path; a peer can"
echo "move a DIFFERENT peer's score (Success, digests above), the node itself cannot"
echo "(code 4), and no single signer can move a score by more than 15 per minute"
echo "(codes 6 and 7) - a compromised peer's damage is bounded until it is revoked."
summary
