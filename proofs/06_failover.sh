#!/usr/bin/env bash
# CONCEPT 6 - FAILOVER (FM1-FM5, FO1-FO5). A silent parent is replaced by an
# eligible follower; takeover is on-chain; one winner per epoch.
cd "$(dirname "$0")/.." && source scripts/env.sh
clean() {
  sed 's/[│┌┐└┘├┤─╭╮╰╯|┬┼┴]//g' \
  | grep -iE 'Transaction Digest|^ *Status:|aborted within|with code [0-9]|Error executing|ParentChanged|new_parent|old_parent|epoch [0-9]|accepted ' \
  | sed -E 's/  +/ /g; s/^ +//; /^$/d; s/^/    /'
}
read_cluster() {
  sui client object "$CLUSTER" --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); f=d.get('content',{})
print('    current_parent   :', f.get('current_parent'))
print('    epoch            :', f.get('epoch'))
print('    trust_gate       :', f.get('trust_gate'))
print('    lease_expires_ms :', f.get('lease_expires_ms'))
"
}
gp(){ sui client object "$CLUSTER" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('content',{}).get('$1','?'))"; }

# Determine which node is the current parent, so we renew from the right container.
CUR_PARENT=$(gp current_parent)
case "$CUR_PARENT" in
  "$RPI1") PARENT_IP=10.25.96.200 ;;
  "$RPI2") PARENT_IP=10.25.96.201 ;;
  "$RPI3") PARENT_IP=10.25.96.203 ;;
  *) PARENT_IP=10.25.96.200 ;;
esac
# The follower that will take over is whichever eligible node is NOT the parent.
# Claimer = an eligible node that is NOT the current parent. Racer = a third node.
if [ "$CUR_PARENT" = "$RPI1" ]; then
  CLAIM_IP=10.25.96.201; CLAIM_NAME="rpi2"; CLAIM_ADDR=$RPI2; RACE_IP=10.25.96.203; RACE_NAME="rpi3"
elif [ "$CUR_PARENT" = "$RPI2" ]; then
  CLAIM_IP=10.25.96.203; CLAIM_NAME="rpi3"; CLAIM_ADDR=$RPI3; RACE_IP=10.25.96.200; RACE_NAME="rpi1"
else
  CLAIM_IP=10.25.96.201; CLAIM_NAME="rpi2"; CLAIM_ADDR=$RPI2; RACE_IP=10.25.96.200; RACE_NAME="rpi1"
fi

echo
echo "################################################################################"
echo "#  CONCEPT 6 - FAILOVER"
echo "################################################################################"
echo
echo "=== SETUP: current parent expires its own lease (simulates going silent) ==="
echo "    The current parent ($CLAIM_NAME will take over) renews its lease to 0ms so"
echo "    it lapses immediately - the on-chain equivalent of missing heartbeats."
echo
sshpass -p user ssh user@$PARENT_IP \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module failover --function renew_lease \
     --args $CLUSTER 0 0x6 --gas-budget 50000000 2>&1 | grep -iE 'Status:|MoveAbort' | head -1" | clean
# wait until the lease is actually in the past before the claim
sleep 3
echo
echo "=== STATE BEFORE: the cluster object on-chain ==="
echo
echo "\$ sui client object $CLUSTER --json"
echo
read_cluster; EB=$(gp epoch); PB=$(gp current_parent)
echo
echo "=== THE OPERATION: $CLAIM_NAME claims the parent role (signed by its OWN key) ==="
echo
echo "\$ docker exec om2m-active sui client call --module failover --function claim_parent \\"
echo "    --args $CLUSTER $IDENTITY_REG $TRUST_REG 0x6   (as $CLAIM_NAME)"
echo
sshpass -p user ssh user@$CLAIM_IP \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module failover --function claim_parent \
     --args $CLUSTER $IDENTITY_REG $TRUST_REG 0x6 --gas-budget 50000000" | clean
sleep 3
echo
echo "=== STATE AFTER: the same object, re-read ==="
echo
read_cluster; EA=$(gp epoch); PA=$(gp current_parent)
echo
echo "    current_parent:  $PB  ->  $PA"
echo "    epoch:           $EB  ->  $EA"
echo
echo "=== THE RACE: $RACE_NAME claims the same seat after the lease just advanced ==="
echo
echo "\$ docker exec om2m-active sui client call ... claim_parent   (as $RACE_NAME)"
echo
RACE=$(sshpass -p user ssh user@$RACE_IP \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module failover --function claim_parent \
     --args $CLUSTER $IDENTITY_REG $TRUST_REG 0x6 --gas-budget 50000000 2>&1")
echo "$RACE" | clean
RC=$(echo "$RACE" | grep -oE 'with code [0-9]+' | grep -oE '[0-9]+' | head -1)
[ "$RC" = "3" ] && echo "    (abort code 3 = E_LEASE_STILL_VALID - seat already taken this epoch)"
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: parent and epoch are on-chain state; when the parent's lease"
echo "lapses, an eligible follower claims and the epoch advances by one; a competing"
echo "claim on the freshly-advanced lease is rejected (code 3). One parent per epoch."
echo "--------------------------------------------------------------------------------"
