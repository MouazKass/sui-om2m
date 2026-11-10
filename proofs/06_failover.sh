#!/usr/bin/env bash
# CONCEPT 6 - FAILOVER (FM1-FM5, FO1-FO5, A10).
# Parent and epoch are on-chain state. The on-chain rules are exercised with
# each node's own key: an over-long or foreign lease renewal is refused, a
# claim on a valid lease is refused, and once the lease lapses exactly one
# follower wins. The script then watches the LIVE plugins converge on the new
# parent without any help (the new parent must start anchoring its lease).
#
# Disruptive: it moves the parent role. The cluster is left healthy (new
# parent anchoring), which the final assertion checks.
PROOF_ID=06; source "$(dirname "$0")/lib_v8.sh"
banner "CONCEPT 6 - FAILOVER"

show_cluster() {
  obj_json "$CLUSTER" | python -c "
import sys,json,time
f=json.load(sys.stdin)['content']; now=int(time.time()*1000); le=int(f['lease_expires_ms'])
print('    current_parent   :', f['current_parent'])
print('    epoch            :', f['epoch'], '| trust_gate:', f['trust_gate'])
print('    lease_expires_ms :', le, '(%+.0f s from now)' % ((le-now)/1000))"
}

P=$(name_of "$(cluster_field current_parent)")
case "$P" in rpi1) C=rpi2; R=rpi3 ;; rpi2) C=rpi3; R=rpi1 ;; rpi3) C=rpi2; R=rpi1 ;; *) echo "unknown parent $P"; exit 1 ;; esac
echo "    parent=$P   claimer=$C   racer=$R"
echo
echo "=== STATE BEFORE ==="; show_cluster; EB=$(cluster_field epoch); echo

echo "=== v8 / A10: THE PARENT CANNOT TAKE A LEASE LONGER THAN MAX_LEASE_MS (1 h) ==="
node_call "$P" failover renew_lease "$CLUSTER" 3600001 0x6
expect "renew 3,600,001 ms rejected (E_LEASE_TOO_LONG)" abort 7
echo
echo "=== A NON-PARENT CANNOT RENEW THE LEASE ==="
node_call "$C" failover renew_lease "$CLUSTER" 60000 0x6
expect "$C renewing $P's lease rejected (E_NOT_PARENT_ROLE)" abort 4
echo
echo "=== A CLAIM WHILE THE LEASE IS VALID IS REFUSED ==="
node_call "$C" failover claim_parent "$CLUSTER" "$IDENTITY_REG" "$TRUST_REG" 0x6
expect "$C claim on a valid lease rejected (E_LEASE_STILL_VALID)" abort 3
echo

echo "=== SETUP: the parent lets its lease lapse (renew to 0 ms = gone silent on-chain) ==="
node_call "$P" failover renew_lease "$CLUSTER" 0 0x6
expect "$P renews to 0 ms" success
sleep 3
echo
echo "=== THE TAKEOVER: $C claims the parent role with its own key ==="
T0=$(date +%s)
node_call "$C" failover claim_parent "$CLUSTER" "$IDENTITY_REG" "$TRUST_REG" 0x6
expect "$C claim after lapse accepted" success
CLAIM_D=$LAST_DIGEST
echo
echo "=== THE RACE: $R claims the same seat right after ==="
node_call "$R" failover claim_parent "$CLUSTER" "$IDENTITY_REG" "$TRUST_REG" 0x6
expect "$R second claim rejected - one winner per epoch (E_LEASE_STILL_VALID)" abort 3
echo
echo "=== STATE AFTER ==="; show_cluster; EA=$(cluster_field epoch)
echo "    epoch: $EB -> $EA"
[ "$EA" = "$((EB+1))" ] && { echo "    [PASS] epoch advanced by exactly one"; PROOF_PASS=$((${PROOF_PASS:-0}+1)); } \
                        || { echo "    [FAIL] epoch $EB -> $EA"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1)); }
echo

echo "=== THE LIVE SYSTEM CONVERGES (no human action): $C's plugin must take up parent duties ==="
echo "    claim_parent grants only a 60 s lease, so $C has to anchor a fresh one itself."
WAIT=${CONVERGE_S:-120}; echo "    (watching for ${WAIT} s)"; sleep "$WAIT"
for n in rpi1 rpi2 rpi3; do
  echo "    [$n]"; on "$n" "docker logs --since $((WAIT+40))s om2m-active 2>&1 | grep -E 'Cluster current parent|Lease anchored|Parent duties|PoA published|CLAIM ACCEPTED|claim gate|took up parent|Self-parent' | tail -4" | sed 's/^/      /'
done
show_cluster
LE=$(cluster_field lease_expires_ms); NOW=$(( $(date +%s) * 1000 ))
if [ "$(name_of "$(cluster_field current_parent)")" = "$C" ] && [ "$LE" -gt $((NOW + 120000)) ]; then
  echo "    [PASS] $C is parent and has anchored a lease beyond the 60 s claim lease"; PROOF_PASS=$((${PROOF_PASS:-0}+1))
else
  echo "    [FAIL] cluster did not converge: parent=$(name_of "$(cluster_field current_parent)") lease_expires_ms=$LE now=$NOW"
  PROOF_FAIL=$((${PROOF_FAIL:-0}+1))
fi
echo
hr
echo "WHAT THIS SHOWS: parent, lease and epoch are on-chain; renewals are bounded and"
echo "parent-only; a claim needs a lapsed lease; exactly one follower wins and the epoch"
echo "advances by one; and the running plugins converge on the winner by themselves."
summary
