#!/usr/bin/env bash
# CONCEPT 6 - FAILOVER (FM1-FM5, FO1-FO5). A silent parent is replaced by an
# eligible follower; takeover is on-chain; one winner per epoch.
cd "$(dirname "$0")/.." && source scripts/env.sh

read_cluster() {
  sui client object "$CLUSTER" --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); f=d.get('content',{})
print('    current_parent   :', f.get('current_parent'))
print('    epoch            :', f.get('epoch'))
print('    trust_gate       :', f.get('trust_gate'))
print('    lease_expires_ms :', f.get('lease_expires_ms'))
" 2>/dev/null
}
get_epoch() {
  sui client object "$CLUSTER" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('content',{}).get('epoch','?'))" 2>/dev/null
}
get_parent() {
  sui client object "$CLUSTER" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('content',{}).get('current_parent','?'))" 2>/dev/null
}

echo
echo "################################################################################"
echo "#  CONCEPT 6 - FAILOVER"
echo "################################################################################"
echo
echo "=== STATE BEFORE: the cluster object on-chain ==="
echo
echo "\$ sui client object $CLUSTER --json"
echo
read_cluster
EP_BEFORE=$(get_epoch); PA_BEFORE=$(get_parent)
echo
echo "=== THE OPERATION: rpi2 claims the parent role (signed by rpi2's OWN key) ==="
echo "    candidate = tx sender; rpi2 is registered with trust 75 >= gate 50."
echo
echo "\$ docker exec om2m-active sui client call \\"
echo "    --package $PKG_V7 \\"
echo "    --module failover --function claim_parent \\"
echo "    --args $CLUSTER \\"
echo "           $IDENTITY_REG \\"
echo "           $TRUST_REG \\"
echo "           0x6 \\"
echo "    --gas-budget 50000000"
echo
sshpass -p user ssh user@10.25.96.201 \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module failover --function claim_parent \
     --args $CLUSTER $IDENTITY_REG $TRUST_REG 0x6 \
     --gas-budget 50000000 2>&1 | grep -iE 'Transaction Digest|Status|MoveAbort' | head -3 | sed 's/^/    /'"
sleep 3
echo
echo "=== STATE AFTER: the same object, re-read ==="
echo
read_cluster
EP_AFTER=$(get_epoch); PA_AFTER=$(get_parent)
echo
echo "    current_parent:  $PA_BEFORE  ->  $PA_AFTER"
echo "    epoch:           $EP_BEFORE  ->  $EP_AFTER"
echo
echo "=== THE RACE: rpi3 claims the same seat after the lease just advanced ==="
echo
echo "\$ docker exec om2m-active sui client call ... claim_parent (as rpi3)"
echo
sshpass -p user ssh user@10.25.96.203 \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module failover --function claim_parent \
     --args $CLUSTER $IDENTITY_REG $TRUST_REG 0x6 \
     --gas-budget 50000000 2>&1 | grep -iE 'MoveAbort|Status|abort' | head -3 | sed 's/^/    /'"
echo
echo "    abort code 3 = E_LEASE_STILL_VALID (seat already taken this epoch)"
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: parent and epoch are on-chain state; an eligible follower's"
echo "claim moves the parent to rpi2 and advances the epoch; a competing claim on the"
echo "same lease is rejected (code 3). One parent per epoch."
echo "--------------------------------------------------------------------------------"
