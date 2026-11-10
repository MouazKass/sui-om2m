#!/usr/bin/env bash
# 01_transfer_upgradecap.sh - V9_DESIGN.md phase D: hand the UpgradeCap to the multisig.
#
#   scripts/v9/01_transfer_upgradecap.sh            # DRY RUN (default)
#   scripts/v9/01_transfer_upgradecap.sh --execute  # transfer for real
#
# Run in WSL as the publisher. After --execute the publisher can no longer
# upgrade the package alone; every upgrade needs MS_THRESHOLD of the multisig's
# signers (3 of 5: publisher, rpi1, rpi3, rpi4, rpi5). Undoing it needs that many
# signers too (a multisig-signed transfer back).
#
# Idempotent: if the UpgradeCap is already owned by the multisig it only
# reports that.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
MODE="${1:---dry-run}"

require_cli; require_publisher; require_multisig

say "current state"
owner=$(object_owner "$UPGRADE_CAP")
echo "UpgradeCap $UPGRADE_CAP owner: $owner"
if [ "$owner" = "AddressOwner:$UPGRADE_MULTISIG" ]; then
  echo "already owned by the multisig $UPGRADE_MULTISIG; nothing to do"; exit 0
fi
[ "$owner" = "AddressOwner:$PUBLISHER" ] || die "UpgradeCap is owned by $owner, not the publisher; stop and investigate"

bal=$(sui_balance "$UPGRADE_MULTISIG")
echo "multisig gas balance: $bal MIST"
# An UpgradeCap held by an address that cannot pay gas is a package nobody can
# upgrade, so funding gates --execute. The dry run below still runs unfunded.
FUNDED=yes; [ "${bal:-0}" -ge 500000000 ] || FUNDED=no

say "the exact transaction"
echo "$SUI client transfer --to $UPGRADE_MULTISIG --object-id $UPGRADE_CAP --gas-budget 10000000"
echo "  signer: $PUBLISHER (publisher)"
echo "  effect: package $PKG_V8 can then only be upgraded by $MS_THRESHOLD-of-$(wc -w <<<"$MS_PKS") of:"
read -r -a _l <<<"${MS_LABELS:-}"; i=0
for pk in $MS_PKS; do echo "          $pk  ${_l[$i]:-}"; i=$((i+1)); done

say "dry run (nothing is signed)"
"$SUI" client transfer --to "$UPGRADE_MULTISIG" --object-id "$UPGRADE_CAP" --gas-budget 10000000 --dry-run --json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); e=d.get("effects",d); print("status:", e.get("status"))'

if [ "$MODE" != "--execute" ]; then
  echo
  [ "$FUNDED" = yes ] || echo "NOTE: fund $UPGRADE_MULTISIG with >= 0.5 SUI before --execute (now $bal MIST)."
  echo "DRY RUN complete. Re-run with --execute to transfer."; exit 0
fi
[ "$FUNDED" = yes ] || die "fund $UPGRADE_MULTISIG with >= 0.5 SUI first: an upgrade it cannot pay for is a locked package"

confirm "transfer upgradecap to $UPGRADE_MULTISIG"
say "transferring"
"$SUI" client transfer --to "$UPGRADE_MULTISIG" --object-id "$UPGRADE_CAP" --gas-budget 10000000 --json > "$V9_DIR/transfer_upgradecap.json"
tx=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["digest"])' "$V9_DIR/transfer_upgradecap.json")
record UPGRADE_CAP_TRANSFER_TX "$tx"
owner=$(object_owner "$UPGRADE_CAP")
[ "$owner" = "AddressOwner:$UPGRADE_MULTISIG" ] || die "transfer tx $tx done but owner reads $owner"
echo "OK: UpgradeCap now owned by $UPGRADE_MULTISIG (tx $tx)"
echo "Next upgrade: scripts/v9/upgrade_multisig.sh <3 signers>  (Git Bash; see V9_SIGNERS.md)"
