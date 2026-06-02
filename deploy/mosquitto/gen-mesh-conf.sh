#!/bin/bash
# Generates a per-node mosquitto.conf that bridges to the other two Pis.
# Usage: gen-mesh-conf.sh <self-ip> <peer1-ip> <peer2-ip>
SELF=$1; P1=$2; P2=$3
cat <<CONF
listener 1883 0.0.0.0
allow_anonymous true
persistence true
persistence_location /mosquitto/data/

# --- Bridge to peer 1 ---
connection bridge-${P1}
address ${P1}:1883
topic om2m/trust/obs/# both 0
topic om2m/failover/# both 0
bridge_attempt_unsubscribe false
restart_timeout 5
cleansession true

# --- Bridge to peer 2 ---
connection bridge-${P2}
address ${P2}:1883
topic om2m/trust/obs/# both 0
topic om2m/failover/# both 0
bridge_attempt_unsubscribe false
restart_timeout 5
cleansession true
CONF
