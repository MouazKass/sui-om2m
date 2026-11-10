#!/usr/bin/env bash
# ============================================================================
# INVARIANT INFRASTRUCTURE PROOFS - master runner (v8)
# Runs each concept's proof against the LIVE v8 deployment and shows the raw
# on-chain evidence (digests, abort codes, object state). Each proof ends with
# a RESULT line counting the assertions that held.
#
# Prereqs: Git Bash on the laptop; the node SSH key (~/.ssh/id_ed25519_suiom2m,
#   override with SSH_KEY); the VPN to the Pis; WSL Ubuntu with the publisher's
#   sui CLI (used for reads and for the publisher-signed steps of 07 and 09).
#   IDs come from deploy/v8/env.v8.sh (generated from deploy/v8/deployment.env).
#
#   proofs/run_all.sh            # interactive, pauses between concepts
#   BATCH=1 proofs/run_all.sh    # no pauses; exit status = number of failed proofs
#   PROOF_LOG=file.csv ...       # append every transaction (digest, outcome, gas)
#
# 06 moves the parent role to another node (and checks the cluster converges).
# 07 and 09 write trust scores and caps but restore what they change.
# ============================================================================
cd "$(dirname "$0")"
FAILED=0
for s in 01_self_scoring 02_trust_engine 03_capability_tokens 04_atomic_ptb \
         05_policy 06_failover 07_evolving_tokens 08_audit_trail \
         09_admin_revocation 10_system_logs; do
  echo ""
  echo "################################################################"
  echo "#  $s"
  echo "################################################################"
  bash "$s.sh" || { FAILED=$((FAILED+1)); echo "!! $s reported failures"; }
  echo ""
  echo "----------------------------------------------------------------"
  [ "${BATCH:-0}" = 1 ] || read -p "Press ENTER for the next concept (or Ctrl-C to stop)... " _
done
echo "All concept proofs run; $FAILED reported failures."
exit "$FAILED"
