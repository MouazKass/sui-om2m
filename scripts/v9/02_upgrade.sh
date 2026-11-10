#!/usr/bin/env bash
# 02_upgrade.sh - V9_DESIGN.md phase E: the v8 -> v9 compatible upgrade, signed 2-of-3.
#
# Run in WSL. Builds from a throwaway copy of move/ so the newer CLI never
# rewrites the committed Move.lock / Published.toml.
#
#   02_upgrade.sh dry-run            free on-chain compatibility check + gas estimate.
#                                    Works before phase D (publisher as sender) and
#                                    after it (multisig as sender).
#   02_upgrade.sh build              serialize the UNSIGNED upgrade tx with the multisig
#                                    as sender -> deploy/v9/upgrade.tx.b64. Send that file
#                                    to two signers (V9_SIGNERS.md).
#   02_upgrade.sh combine SIG1 SIG2  combine two signers' suiSignature values
#                                    -> deploy/v9/upgrade.multisig
#   02_upgrade.sh execute            submit tx + multisig, record PKG_V9
#   02_upgrade.sh direct             OPTION A (2026-11-10): the publisher still holds the
#                                    UpgradeCap and signs the upgrade itself. Refuses if the
#                                    cap has moved to a multisig. Needs CONFIRM='upgrade <v8> to v9'
#                                    when not interactive.
#
# Rebuild ("build") whenever the gas coin used in the tx changes: signatures
# cover the exact bytes, so a stale tx must be rebuilt and re-signed.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
CMD="${1:-}"; shift || true
GAS_BUDGET="${GAS_BUDGET:-500000000}"
TX_FILE="$V9_DIR/upgrade.tx.b64"
SIG_FILE="$V9_DIR/upgrade.multisig"

require_cli; check_move_lock

if [ -n "${PKG_V9:-}" ] && [ "$CMD" != "dry-run" ]; then
  echo "v9 already recorded: PKG_V9=$PKG_V9 (tx ${UPGRADE_TX:-?}); nothing to do"; exit 0
fi

# Fresh copy of the package for every build; removed on exit.
stage() {
  BUILD=$(mktemp -d /tmp/sui-om2m-v9.XXXXXX)
  trap 'rm -rf "$BUILD"' EXIT
  cp -r "$REPO/move/." "$BUILD/"
  rm -rf "$BUILD/build"
  cd "$BUILD"
  "$SUI" move test 2>&1 | tail -1 | grep -q "Test result: OK" || die "move tests failing on $("$SUI" --version)"
}

upgrade_owner() { object_owner "$UPGRADE_CAP"; }

# record_upgrade <upgrade.json>: check success, record PKG_V9 + UPGRADE_TX.
record_upgrade() {
  python3 - "$1" > "$V9_DIR/upgrade.ids" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
st=d["effects"]["status"]
if st.get("status")!="success": sys.exit(f"FATAL: upgrade failed: {st}")
pkg=[c["packageId"] for c in d.get("objectChanges",[]) if c.get("type")=="published"]
if len(pkg)!=1: sys.exit(f"FATAL: expected one published package, got {pkg}")
print(pkg[0], d["digest"])
PY
  local pkg tx; read -r pkg tx < "$V9_DIR/upgrade.ids"; rm -f "$V9_DIR/upgrade.ids"
  record PKG_V9 "$pkg"; record UPGRADE_TX "$tx"
  check_v9_package "$pkg"
  echo "OK: v9 published at $pkg (tx $tx). Types keep the original id $PKG_V8."
  echo "Update move/Published.toml (published-at=$pkg, version=2) in the repo, then"
  echo "      scripts/v9/03_switch_plugin.sh v9"
}

case "$CMD" in
  dry-run)
    stage
    owner=$(upgrade_owner)
    case "$owner" in
      "AddressOwner:$PUBLISHER")  sender=$PUBLISHER; echo "UpgradeCap still with the publisher: dry run as publisher";;
      "AddressOwner:"*)           require_multisig; sender=$UPGRADE_MULTISIG; echo "dry run as multisig $sender";;
      *) die "unexpected UpgradeCap owner $owner";;
    esac
    say "on-chain upgrade dry run (nothing is signed or spent)"
    args=(client upgrade --upgrade-capability "$UPGRADE_CAP" --gas-budget "$GAS_BUDGET" --dry-run --json)
    [ "$sender" != "$PUBLISHER" ] && args+=(--sender "$sender")
    "$SUI" "${args[@]}" > "$V9_DIR/upgrade.dryrun.json"
    python3 - "$V9_DIR/upgrade.dryrun.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
e=d.get("effects",{}); st=e.get("status",{}); g=e.get("gasUsed",{})
cost=int(g.get("computationCost",0))+int(g.get("storageCost",0))-int(g.get("storageRebate",0))
print("status:", st.get("status"), st.get("error",""))
print(f"estimated net gas: {cost} MIST = {cost/1e9:.4f} SUI  (computation {g.get('computationCost')}, storage {g.get('storageCost')}, rebate {g.get('storageRebate')})")
for c in d.get("objectChanges",[]):
    print(" ", c.get("type"), c.get("objectType", c.get("packageId","")))
sys.exit(0 if st.get("status")=="success" else 1)
PY
    ;;

  build)
    require_multisig
    [ "$(upgrade_owner)" = "AddressOwner:$UPGRADE_MULTISIG" ] || die "UpgradeCap is not owned by the multisig yet; run 01_transfer_upgradecap.sh --execute"
    stage
    say "serialize unsigned upgrade tx (sender $UPGRADE_MULTISIG)"
    "$SUI" client upgrade --upgrade-capability "$UPGRADE_CAP" --sender "$UPGRADE_MULTISIG" \
      --gas-budget "$GAS_BUDGET" --serialize-unsigned-transaction > "$TX_FILE.raw"
    tail -1 "$TX_FILE.raw" | tr -d '[:space:]' > "$TX_FILE"; rm -f "$TX_FILE.raw" "$SIG_FILE"
    echo "wrote $TX_FILE ($(wc -c < "$TX_FILE") chars, sha256 $(sha256sum "$TX_FILE" | cut -c1-16))"
    echo
    echo "Send $TX_FILE to two signers. Each runs (V9_SIGNERS.md):"
    echo "  sui keytool sign --address <their-address> --data \"\$(cat upgrade.tx.b64)\""
    echo "and returns the suiSignature value. Then: $0 combine <sig1> <sig2>"
    ;;

  combine)
    require_multisig
    [ $# -ge 2 ] || die "usage: $0 combine <suiSignature1> <suiSignature2> [sig3]"
    [ -f "$TX_FILE" ] || die "no $TX_FILE; run '$0 build' first"
    # The CLI needs sigs in the same order as --pks. Each suiSignature is
    # flag||sig||pk, so order them by their embedded key instead of trusting
    # the order they were pasted in, and reject a sig from a non-member key.
    # shellcheck disable=SC2086
    mapfile -t ORDERED < <(python3 - "$MS_PKS" "$@" <<'PY'
import base64,sys
pks=sys.argv[1].split(); sigs=sys.argv[2:]
idx={}
for s in sigs:
    raw=base64.b64decode(s)
    if len(raw)!=97 or raw[0]!=0x00: sys.exit(f"FATAL: not an ed25519 suiSignature: {s[:16]}...")
    pk=base64.b64encode(raw[:1]+raw[65:]).decode()
    if pk not in pks: sys.exit(f"FATAL: signature from a key that is not a multisig member: {pk}")
    if pks.index(pk) in idx: sys.exit(f"FATAL: two signatures from the same key {pk}")
    idx[pks.index(pk)]=s
for i in sorted(idx): print(idx[i])
PY
)
    [ "${#ORDERED[@]}" -ge "$MS_THRESHOLD" ] || die "need $MS_THRESHOLD distinct member signatures, got ${#ORDERED[@]}"
    # shellcheck disable=SC2086
    "$SUI" keytool --json multi-sig-combine-partial-sig --pks $MS_PKS --weights $MS_WEIGHTS \
      --threshold "$MS_THRESHOLD" --sigs "${ORDERED[@]}" > "$V9_DIR/upgrade.multisig.json"
    python3 - "$V9_DIR/upgrade.multisig.json" "$UPGRADE_MULTISIG" "$SIG_FILE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
addr=d.get("multisigAddress")
if addr and addr!=sys.argv[2]:
    sys.exit(f"FATAL: combined signature is for {addr}, expected {sys.argv[2]} (key order?)")
open(sys.argv[3],"w").write(d["multisigSerialized"])
print("combined multisig signature ->", sys.argv[3])
PY
    ;;

  execute)
    require_multisig
    [ -f "$TX_FILE" ] && [ -f "$SIG_FILE" ] || die "need $TX_FILE and $SIG_FILE (build, then combine)"
    confirm "upgrade $PKG_V8 to v9"
    say "executing the multisig-signed upgrade"
    "$SUI" client execute-signed-tx --tx-bytes "$(cat "$TX_FILE")" --signatures "$(cat "$SIG_FILE")" --json > "$V9_DIR/upgrade.json"
    record_upgrade "$V9_DIR/upgrade.json"
    ;;

  direct)
    require_publisher
    [ "$(upgrade_owner)" = "AddressOwner:$PUBLISHER" ]       || die "UpgradeCap is owned by $(upgrade_owner), not the publisher: use build/combine/execute (multisig)"
    stage
    confirm "upgrade $PKG_V8 to v9"
    say "executing the publisher-signed upgrade (option A)"
    "$SUI" client upgrade --upgrade-capability "$UPGRADE_CAP" --gas-budget "$GAS_BUDGET" --json > "$V9_DIR/upgrade.json"
    record_upgrade "$V9_DIR/upgrade.json"
    ;;

  *) sed -n '2,24p' "$0"; exit 1;;
esac
