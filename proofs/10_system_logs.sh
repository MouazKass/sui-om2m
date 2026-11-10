#!/usr/bin/env bash
# CONCEPT 10 - LIVE SYSTEM LOGS. The plugin's own logs, pulled fresh from the
# running containers: access decisions, the autonomous trust engine, signed
# gossip, and the failover manager. (v8: key-based SSH, v8 log lines.)
PROOF_ID=10; source "$(dirname "$0")/lib_v8.sh"
banner "CONCEPT 10 - LIVE SYSTEM LOGS (pulled fresh from the running nodes)"
strip() { sed -E 's/^\[(INFO|WARN|ERROR)\] - [A-Za-z0-9_.$]+ *//; /^\s*$/d; s/^/    /' | cut -c1-170; }
grab() {  # <node> <since> <regex> <n>
  on "$1" "docker logs --since $2 om2m-active 2>&1 | grep -E '$3' | tail -$4" | strip
}
check() {  # <label> <node> <since> <regex>
  if on "$2" "docker logs --since $3 om2m-active 2>&1 | grep -qE '$4'"; then echo "    [PASS] $1"; PROOF_PASS=$((${PROOF_PASS:-0}+1))
  else echo "    [FAIL] $1"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1)); fi
}

echo "=== PLUGIN STARTUP (rpi3): subsystems initialise in order ==="
grab rpi3 24h 'sui-debug\] step|Plugin ready|NativePtbBuilder ready|engine started|gossip signing' 8
check "rpi3 plugin is up" rpi3 24h 'Plugin ready'
echo
echo "=== ACCESS DECISIONS (rpi3): ordinary oneM2M requests decided on-chain ==="
grab rpi3 24h 'Sui DAC consult|Sui GRANT|Sui DENY' 6
check "rpi3 logged an on-chain decision" rpi3 24h 'Sui (GRANT|DENY)'
echo
echo "=== TRUST ENGINE (rpi2): autonomous peer scoring ==="
grab rpi2 30m '\[trust\]' 6
check "rpi2 trust engine running" rpi2 24h '\[trust\] engine started'
echo
echo "=== SIGNED GOSSIP (rpi1): the peer-attestation channel ==="
grab rpi1 24h 'gossip' 4
check "rpi1 gossip is signed" rpi1 24h 'gossip signing ENABLED'
echo
echo "=== FAILOVER (all nodes): who is parent, and the parent anchoring its lease ==="
for n in rpi1 rpi2 rpi3; do echo "  [$n]"; grab "$n" 2h 'Cluster current parent|Lease anchored|PoA published|Parent duties|Chain names this node' 3; done
P=$(name_of "$(cluster_field current_parent)")
check "the on-chain parent ($P) has anchored its lease" "$P" 30m 'Lease anchored'
echo
hr
echo "WHAT THIS SHOWS: the subsystems are live on the real nodes - the DAS deciding"
echo "ordinary requests on-chain, the trust engine scoring peers, signed gossip, and"
echo "the failover manager following the chain's parent. This is the running system."
summary
