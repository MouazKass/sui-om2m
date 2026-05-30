#!/usr/bin/env bash
#
# deploy_sui_package.sh
#
# Publishes the Move package to Sui testnet and extracts the IDs of all
# shared registry objects and capabilities created by the `init`
# functions. Writes them out as `sui.properties` fragments ready to
# paste into each node's config.
#
# Prereqs on the Pi running this:
#   * sui CLI installed and `sui client active-env` -> testnet
#   * sui client active-address has testnet gas (request from faucet or
#     ask Kostas for an elevated allocation)
#
# Usage:
#   cd /home/claude/sui-om2m/move
#   ../scripts/deploy_sui_package.sh
#

set -euo pipefail

cd "$(dirname "$0")/../move"

echo "==> Building package"
sui move build

echo "==> Publishing to $(sui client active-env)"
PUBLISH_OUT=$(sui client publish --gas-budget 200000000 --json)
echo "$PUBLISH_OUT" > /tmp/sui_publish_output.json

# Package ID
PKG=$(echo "$PUBLISH_OUT" | jq -r '
  .objectChanges[] | select(.type=="published") | .packageId')

# Shared objects, keyed by their Move type. The `init` functions in
# each module emit one shared registry/trail/etc. and one cap object.
extract_shared() {
  local type_suffix="$1"
  echo "$PUBLISH_OUT" | jq -r --arg t "$type_suffix" '
    .objectChanges[]
    | select(.type=="created")
    | select(.owner=="Shared" or (.owner|type=="object" and (.owner|has("Shared"))))
    | select(.objectType | endswith($t))
    | .objectId' | head -n1
}

extract_owned() {
  local type_suffix="$1"
  echo "$PUBLISH_OUT" | jq -r --arg t "$type_suffix" '
    .objectChanges[]
    | select(.type=="created")
    | select(.objectType | endswith($t))
    | .objectId' | head -n1
}

IDENTITY_REG=$(extract_shared "::identity::Registry")
TRUST_REG=$(extract_shared    "::trust::TrustRegistry")
POLICY_REG=$(extract_shared   "::policy::PolicyRegistry")
AUDIT_TRAIL=$(extract_shared  "::audit::AuditTrail")

ISSUER_CAP=$(extract_owned   "::cap_token::IssuerCap")
ID_ADMIN_CAP=$(extract_owned "::identity::AdminCap")
TR_ADMIN_CAP=$(extract_owned "::trust::AdminCap")
POL_ADMIN_CAP=$(extract_owned "::policy::PolicyAdminCap")
AUDIT_ADMIN_CAP=$(extract_owned "::audit::AuditAdminCap")

cat <<EOF

==================================================================
Published successfully. Paste the following into sui.properties:
==================================================================

sui.package.id=$PKG
sui.identity.registry.id=$IDENTITY_REG
sui.trust.registry.id=$TRUST_REG
sui.policy.registry.id=$POLICY_REG
sui.audit.trail.id=$AUDIT_TRAIL

Owned caps (held by the publisher's address — keep these safe):
  IssuerCap         : $ISSUER_CAP
  Identity AdminCap : $ID_ADMIN_CAP
  Trust AdminCap    : $TR_ADMIN_CAP
  Policy AdminCap   : $POL_ADMIN_CAP
  Audit AdminCap    : $AUDIT_ADMIN_CAP

==================================================================

Next: bootstrap the failover cluster object with:
  sui client call \\
    --package $PKG --module failover --function create_cluster \\
    --args '[69,69,95,53]' <initial_parent_addr> 50 60000 0x6 \\
    --gas-budget 20000000

The first arg is the cluster_id as a vector<u8> — '[69,69,95,53]' = "EE_5"
(matching Hammad et al.'s cluster naming).
EOF
