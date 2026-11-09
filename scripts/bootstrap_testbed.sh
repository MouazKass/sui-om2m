#!/usr/bin/env bash
#
# bootstrap_testbed.sh
#
# Once the package is published, this script seeds the on-chain state
# to match the testbed described on slide 9:
#   * 1 IN-CSE at 10.25.96.200
#   * 2 MN-CSEs at 10.25.96.201 and 10.25.96.203
# Each gets registered in identity::Registry, given an initial trust
# score in trust::TrustRegistry, and a policy is installed for a sample
# resource path.
#
# Edit the addresses below before running.

set -euo pipefail

source ./env.sh  # exports PKG, IDENTITY_REG, TRUST_REG, POLICY_REG,
                 # AUDIT_TRAIL, ISSUER_CAP, ID_ADMIN_CAP, TR_ADMIN_CAP,
                 # POL_ADMIN_CAP, AUDIT_ADMIN_CAP, CLOCK

# === EDIT THESE ===
IN_CSE_ADDR=0xINCSE_ADDR_HERE
MN1_ADDR=0xMN1_ADDR_HERE
MN2_ADDR=0xMN2_ADDR_HERE

# OM2M-style resource path used in the demo flow.
SAMPLE_RES="/in-cse/AE-temp/cnt-readings"

# Resource governed by the NATIVE oneM2M dynamic-authorization path (C2).
#
# bench/provision_das.sh Part B creates an <AE> named sui-dac-ae carrying
# acpi=[acp_sui_dac] (grants nothing to the test originator) and
# daci=[sui-dac] (a <dynamicAuthorizationConsultation> pointing at the
# sui-das AE). An ordinary RETRIEVE of that AE therefore reaches the Sui DAS
# through OM2M itself rather than through a hand-crafted NOTIFY.
#
# NOTE the form of this key. DynamicAuthorizationSelector sends the DAS
# resourceEntity.getResourceID() -- the NON-hierarchical id -- not the
# hierarchical path, so the on-chain policy must be keyed by the id.
# provision_das.sh creates that AE with originator "Csui-dac-ae", which makes
# AEController set aeid = From and ri = "/" + CSE_ID + "/" + aeid. The id is
# therefore stable across reboots and this policy only has to be installed once.
# (Had the AE been created as admin:admin, OM2M would mint a random
# "/in-cse/CAE<random>" on every boot and this policy would miss.)
DAC_RES="/in-cse/Csui-dac-ae"

GAS=20000000

echo "==> Register nodes in identity"
sui client call --package "$PKG" --module identity --function register \
  --args "$ID_ADMIN_CAP" "$IDENTITY_REG" "$IN_CSE_ADDR" '"in-cse"'   1 0 \
  --gas-budget $GAS
sui client call --package "$PKG" --module identity --function register \
  --args "$ID_ADMIN_CAP" "$IDENTITY_REG" "$MN1_ADDR"    '"mn-cse-1"' 2 0 \
  --gas-budget $GAS
sui client call --package "$PKG" --module identity --function register \
  --args "$ID_ADMIN_CAP" "$IDENTITY_REG" "$MN2_ADDR"    '"mn-cse-2"' 2 0 \
  --gas-budget $GAS

echo "==> Seed trust scores"
sui client call --package "$PKG" --module trust --function add_node \
  --args "$TR_ADMIN_CAP" "$TRUST_REG" "$IN_CSE_ADDR" 100 "$CLOCK" \
  --gas-budget $GAS
sui client call --package "$PKG" --module trust --function add_node \
  --args "$TR_ADMIN_CAP" "$TRUST_REG" "$MN1_ADDR"    75 "$CLOCK" \
  --gas-budget $GAS
sui client call --package "$PKG" --module trust --function add_node \
  --args "$TR_ADMIN_CAP" "$TRUST_REG" "$MN2_ADDR"    60 "$CLOCK" \
  --gas-budget $GAS

echo "==> Install policy for $SAMPLE_RES"
# allowed_ops_mask = 3 (OP_READ | OP_WRITE), min_trust = 50.
sui client call --package "$PKG" --module policy --function set_policy \
  --args "$POL_ADMIN_CAP" "$POLICY_REG" "\"$SAMPLE_RES\"" 50 3 \
  --gas-budget $GAS

echo "==> Mint a CapToken to MN1 for the sample resource"
# allowed_ops = 1 (OP_READ), expiry_ms = now+1h, max_uses = 1000
NOW_MS=$(date +%s%3N)
NOW_MS=$(date +%s%3N); EXPIRY=$((NOW_MS + 3600000))
sui client call --package "$PKG" --module cap_token --function mint \
  --args "$ISSUER_CAP" "$MN1_ADDR" "\"$SAMPLE_RES\"" 1 $EXPIRY 1000 \
  --gas-budget $GAS

echo "==> Install policy for $DAC_RES (native dynamic-authorization target, C2)"
# Same shape as the sample policy: min_trust = 50, allowed_ops_mask = 3.
# Needed because the DAC path authorizes the AE resource itself, not the
# container used by the NOTIFY-based proof scripts.
sui client call --package "$PKG" --module policy --function set_policy   --args "$POL_ADMIN_CAP" "$POLICY_REG" "\"$DAC_RES\"" 50 3   --gas-budget $GAS

echo "==> Mint a CapToken to IN-CSE for $DAC_RES"
# The DAC probe originator resolves (via configuration/sui.mappings.properties)
# to a Sui address that must hold a CapToken for DAC_RES, else SuiDasService
# logs "No Sui mapping ..." and denies before ever touching the chain.
NOW_MS=$(date +%s%3N); DAC_EXPIRY=$((NOW_MS + 3600000))
sui client call --package "$PKG" --module cap_token --function mint   --args "$ISSUER_CAP" "$IN_CSE_ADDR" "\"$DAC_RES\"" 1 $DAC_EXPIRY 1000   --gas-budget $GAS

echo ""
echo "==> REMINDER: map the DAC probe originator to that address + token in"
echo "    \$OM2M_HOME/configuration/sui.mappings.properties on the node:"
echo "      addr.Csensor-001=<sui address holding the CapToken>"
echo "      token.Csensor-001::$DAC_RES=<CapToken object id>"
echo "    then restart the CSE (SuiConfig reads that file at bundle start)."
echo ""
echo "==> Done. Verify with: sui client objects --address $MN1_ADDR"
