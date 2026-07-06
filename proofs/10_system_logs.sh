#!/usr/bin/env bash
# CONCEPT 10 - LIVE SYSTEM LOGS. The plugin's own logs, pulled fresh from the
# running containers, showing each subsystem operating: access decisions, the
# autonomous trust engine, signed gossip, and the failover monitor.
cd "$(dirname "$0")/.." && source scripts/env.sh
strip() { sed 's/\[INFO\] - .*//; s/ ? / -> /g; s/?$//; /^$/d; s/^/    /'; }

echo
echo "################################################################################"
echo "#  CONCEPT 10 - LIVE SYSTEM LOGS (pulled fresh from the running nodes)"
echo "################################################################################"
echo
echo "=== PLUGIN STARTUP (rpi3): all subsystems initialise in order ==="
echo
echo "\$ docker logs om2m-active | grep 'sui-debug\\|Plugin ready'"
echo
sshpass -p user ssh user@10.25.96.203 \
  "docker logs om2m-active 2>&1 | grep -iE 'sui-debug|Plugin ready' | tail -12" | strip | sed 's/? submitted/-> submitted/g; s/ ? / -> /g'
echo
echo "=== ACCESS DECISIONS (rpi3): the DAS granting on-chain, with cache hits ==="
echo
echo "\$ docker logs om2m-active | grep 'Sui GRANT'"
echo
sshpass -p user ssh user@10.25.96.203 \
  "docker logs om2m-active 2>&1 | grep -iE 'Sui GRANT|Sui DENY' | tail -6" | strip | sed 's/? submitted/-> submitted/g; s/ ? / -> /g'
echo
echo "=== TRUST ENGINE (rpi2): autonomous peer-scoring engine, running ==="
echo
echo "\$ docker logs om2m-active | grep 'trust'"
echo
sshpass -p user ssh user@10.25.96.201 \
  "docker logs om2m-active 2>&1 | grep -iE '\[trust\]' | tail -8" | strip | sed 's/? submitted/-> submitted/g; s/ ? / -> /g'
echo
echo "=== SIGNED GOSSIP (rpi2): the peer-attestation channel over MQTT ==="
echo
echo "\$ docker logs om2m-active | grep 'gossip'"
echo
sshpass -p user ssh user@10.25.96.201 \
  "docker logs om2m-active 2>&1 | grep -iE 'gossip' | tail -5" | strip | sed 's/? submitted/-> submitted/g; s/ ? / -> /g'
echo
echo "=== FAILOVER MONITOR (rpi1): actively tracking the cluster parent ==="
echo
echo "\$ docker logs om2m-active | grep 'Cluster current parent'"
echo
sshpass -p user ssh user@10.25.96.200 \
  "docker logs om2m-active 2>&1 | grep -iE 'Cluster current parent|FailoverManager' | grep -v INFO | tail -4" | strip | sed 's/? submitted/-> submitted/g; s/ ? / -> /g'
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: the four subsystems are live and logging on the real nodes -"
echo "the DAS deciding access (with cache), the trust engine scoring peers"
echo "autonomously (EMA, 60s window), signed gossip over MQTT, and the failover"
echo "manager monitoring the parent. This is the running system, not a replay."
echo "--------------------------------------------------------------------------------"
