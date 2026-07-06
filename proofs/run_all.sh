#!/usr/bin/env bash
# ============================================================================
# INVARIANT INFRASTRUCTURE PROOFS - master runner
# Runs each concept's proof in order, surfacing the RAW on-chain evidence.
# Nothing here prints "PASS" - it shows the actual transactions, digests,
# object state, and contract source so the reader draws the conclusion.
#
# Prereqs: run from the repo root's parent (script cd's to repo root via ..),
#   env.sh sourced with the v7 IDs, laptop wallet + node containers reachable.
# ============================================================================
cd "$(dirname "$0")"
for s in 01_self_scoring 02_trust_engine 03_capability_tokens 04_atomic_ptb \
         05_policy 06_failover 07_evolving_tokens 08_audit_trail; do
  echo ""
  echo "################################################################"
  echo "#  $s"
  echo "################################################################"
  bash "$s.sh"
  echo ""
  echo "----------------------------------------------------------------"
  read -p "Press ENTER for the next concept (or Ctrl-C to stop)... " _
done
echo "All concept proofs shown."
