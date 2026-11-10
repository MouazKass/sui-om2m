#!/usr/bin/env bash
# rehearse_upgrade_live.sh - a REAL testnet rehearsal of the multisig upgrade flow,
# on a throwaway package, with the REAL signer set of deploy/v9/multisig.env.
#
# Run from Git Bash on the laptop:
#   scripts/v9/rehearse_upgrade_live.sh [signer signer signer]   (default: publisher rpi1 rpi3)
#
#   1. publisher publishes a tiny throwaway package (marker::version() = 1)
#   2. publisher transfers that package's UpgradeCap to the multisig
#   3. the multisig is funded if it holds < FUND_MIST in coins (default 0.6 SUI, sent
#      by the node key of FUND_FROM, default rpi3); the gas stays there for real upgrades
#   4. a compatible change is built as an unsigned upgrade with the multisig as sender
#      (scripts/v9/upgrade_multisig.sh --no-execute: build, sign on each machine, combine)
#   5. NEGATIVE: the publisher alone cannot upgrade it any more (dry run, aborts)
#   6. NEGATIVE: a multisig with only threshold-1 signatures is rejected by the network
#   7. the threshold-signed upgrade executes; package version 2 has the new function
#
# Spends ~0.03 SUI. Touches nothing of the live deployment: its own V9_DIR (a temp
# dir holding a copy of multisig.env), its own package, its own UpgradeCap.
# Log: evidence/v9-rollout/multisig_rehearsal_<date>.log
set -euo pipefail
export MSYS_NO_PATHCONV=1
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "FATAL: $*" >&2; exit 1; }
say() { echo; echo "=== $* ==="; }
SIGNERS=("$@"); [ ${#SIGNERS[@]} -gt 0 ] || SIGNERS=(publisher rpi1 rpi3)
FUND_FROM="${FUND_FROM:-rpi3}"
FUND_MIST="${FUND_MIST:-600000000}"   # one real upgrade of move/ costs ~0.21 SUI
LOCK="${CHAIN_LOCK:-}"     # optional mkdir-mutex shared with other on-chain operators
lock()   { [ -z "$LOCK" ] && return 0; until mkdir "$LOCK" 2>/dev/null; do sleep 5; done; }
unlock() { [ -z "$LOCK" ] && return 0; rmdir "$LOCK" 2>/dev/null || true; }
trap unlock EXIT

LOG="$REPO/evidence/v9-rollout/multisig_rehearsal_$(date -u +%F).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "# multisig upgrade rehearsal $(date -u +%FT%TZ), signers: ${SIGNERS[*]}"

. "$REPO/deploy/v9/multisig.env"
MS="$UPGRADE_MULTISIG"
PUB=0xb87fb2af21e29dd292d5b557b92d95a544794a589620f4b437f2247f075d6a1e
SUI_W=/home/mouaz/sui-cli/1.83.1/sui
wslp() { local w; w=$(cygpath -m "$1"); printf '/mnt/%s%s' "$(printf '%s' "${w:0:1}" | tr 'A-Z' 'a-z')" "${w:2}"; }
W() { wsl -d "${WSL_DISTRO:-Ubuntu}" --exec bash -lc "$*"; }
gql() { curl -sS --max-time 20 https://graphql.testnet.sui.io/graphql -H 'content-type: application/json' -d "{\"query\":\"$1\"}"; }
coin_bal() { gql "{ address(address: \\\"$1\\\") { balance(coinType: \\\"0x2::sui::SUI\\\") { coinBalance } } }" \
  | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["data"]["address"]["balance"]["coinBalance"] or 0))'; }

# Mixed C:/... path: readable by Git Bash, Windows python and (via wslp) WSL alike.
# RESUME=<workdir> reuses a workdir whose publish/transfer already ran (steps 1-2 skipped).
if [ -n "${RESUME:-}" ]; then R=$(cygpath -m "$RESUME"); else R=$(cygpath -m "$(mktemp -d)"); fi
RW=$(wslp "$R")
mkdir -p "$R/pkg/sources" "$R/v9"
if [ -z "${RESUME:-}" ]; then
cp "$REPO/deploy/v9/multisig.env" "$R/v9/"
cat > "$R/pkg/Move.toml" <<'EOF'
[package]
name = "upgrade_rehearsal"
edition = "2024"

[addresses]
upgrade_rehearsal = "0x0"
EOF
cat > "$R/pkg/sources/marker.move" <<'EOF'
/// Throwaway package for rehearsing a multisig-signed upgrade. Holds nothing.
module upgrade_rehearsal::marker;

public fun version(): u64 { 1 }
EOF
fi
echo "workdir $R"
echo "multisig $MS (threshold $MS_THRESHOLD of $(wc -w <<<"$MS_PKS"): $MS_LABELS)"

say "1-2. publish the throwaway package, hand its UpgradeCap to the multisig"
lock
[ -s "$R/publish.json" ] || W "cd $RW/pkg && $SUI_W client publish --gas-budget 50000000 --json" > "$R/publish.json"
read -r PKG CAP PUB_TX < <(python3 - "$R/publish.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["effects"]["status"]["status"]=="success", d["effects"]["status"]
pkg=[c["packageId"] for c in d["objectChanges"] if c["type"]=="published"][0]
cap=[c["objectId"] for c in d["objectChanges"] if c["type"]=="created" and c["objectType"].endswith("::package::UpgradeCap")][0]
print(pkg, cap, d["digest"])
PY
)
echo "publish tx $PUB_TX: package $PKG, UpgradeCap $CAP"
[ -s "$R/transfer.json" ] || W "$SUI_W client transfer --to $MS --object-id $CAP --gas-budget 10000000 --json" > "$R/transfer.json"
XFER_TX=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["effects"]["status"]["status"]=="success"; print(d["digest"])' "$R/transfer.json")
echo "transfer tx $XFER_TX: UpgradeCap -> $MS"

say "3. multisig gas"
bal=$(coin_bal "$MS"); echo "multisig coin balance: $bal MIST"
if [ "$bal" -lt "$FUND_MIST" ]; then
  . "$REPO/scripts/lib/inventory.sh"; inv_load
  coin=$(ssh -F "$INV_SSH_CONFIG" -o BatchMode=yes "${INV_IP[$FUND_FROM]}" "docker exec om2m-active sui client gas --json" \
    | python3 -c '
import json,sys
need=int(sys.argv[1])+20000000
g=json.load(sys.stdin); g=g["gasCoins"] if isinstance(g,dict) else g
ok=[c for c in g if int(c["mistBalance"])>=need]
if not ok: sys.exit("FATAL: no single coin on the funding node holds %d MIST" % need)
print(max(ok,key=lambda c:int(c["mistBalance"]))["gasCoinId"])' "$FUND_MIST")
  out=$(ssh -F "$INV_SSH_CONFIG" -o BatchMode=yes "${INV_IP[$FUND_FROM]}" \
    "docker exec om2m-active sui client transfer-sui --to $MS --sui-coin-object-id $coin --amount $FUND_MIST --gas-budget 10000000 --json")
  FUND_TX=$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["effects"]["status"]["status"]=="success"; print(d["digest"])')
  echo "fund tx $FUND_TX: $FUND_MIST MIST from $FUND_FROM -> $MS"
  for _ in 1 2 3 4 5 6; do [ "$(coin_bal "$MS")" -ge "$FUND_MIST" ] && break; sleep 3; done
fi
unlock

say "4. compatible change -> unsigned upgrade, signed on each machine, combined"
grep -q "fun upgraded" "$R/pkg/sources/marker.move" || cat >> "$R/pkg/sources/marker.move" <<'EOF'

/// Added by the multisig-signed upgrade (version 2).
public fun upgraded(): bool { true }
EOF
export V9_DIR="$R/v9" UPGRADE_LABEL=rehearsal PKG_DIR="$R/pkg" UPGRADE_CAP_ID="$CAP" SKIP_PKG_CHECK=1 GAS_BUDGET=100000000
bash "$REPO/scripts/v9/upgrade_multisig.sh" --no-execute "${SIGNERS[@]}"
TX=$(cat "$R/v9/upgrade.tx.b64")

say "5. NEGATIVE: the publisher alone can no longer upgrade"
W "cd $RW/pkg && $SUI_W client upgrade --upgrade-capability $CAP --gas-budget 100000000 --dry-run 2>&1" > "$R/pub_alone.txt" || true
grep -m1 -iE "error|owned by|status" "$R/pub_alone.txt" || tail -2 "$R/pub_alone.txt"
if grep -q "execution status: success" "$R/pub_alone.txt"; then die "publisher could still upgrade alone"; fi
echo "PASS: publisher-only upgrade refused"

say "6. NEGATIVE: $((MS_THRESHOLD-1)) signatures are rejected by the network"
mapfile -t FEW < <(head -n $((MS_THRESHOLD-1)) "$R/v9/upgrade.sigs" | awk '{print $2}')
# shellcheck disable=SC2086
W "$SUI_W keytool --json multi-sig-combine-partial-sig --pks $MS_PKS --weights $MS_WEIGHTS --threshold $MS_THRESHOLD --sigs ${FEW[*]}" > "$R/few.json" 2>&1 || true
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))["multisigSerialized"]' "$R/few.json" 2>/dev/null; then
  FEWSIG=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["multisigSerialized"])' "$R/few.json")
  lock
  W "$SUI_W client execute-signed-tx --tx-bytes $TX --signatures $FEWSIG 2>&1" > "$R/few_exec.txt" || true
  unlock
  if grep -qiE "\"status\": *\"success\"|Status: Success" "$R/few_exec.txt"; then die "a sub-threshold multisig was ACCEPTED"; fi
  echo "network response: $(grep -m1 -iE 'error|insufficient|weight|invalid' "$R/few_exec.txt" || head -c 300 "$R/few_exec.txt")"
  echo "PASS: $((MS_THRESHOLD-1))-of-$(wc -w <<<"$MS_PKS") signature rejected by the network, nothing executed"
else
  echo "CLI refused to even combine: $(head -c 300 "$R/few.json")"
  echo "PASS: $((MS_THRESHOLD-1)) signatures cannot form a valid multisig"
fi

say "7. execute the threshold-signed upgrade"
lock
W "$SUI_W client execute-signed-tx --tx-bytes $TX --signatures $(cat "$R/v9/upgrade.multisig") --json" > "$R/upgrade.json"
unlock
read -r PKG2 UP_TX < <(python3 - "$R/upgrade.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["effects"]["status"]["status"]=="success", d["effects"]["status"]
print([c["packageId"] for c in d["objectChanges"] if c["type"]=="published"][0], d["digest"])
PY
)
echo "upgrade tx $UP_TX: package version 2 at $PKG2"
gql "{ object(address: \\\"$PKG2\\\") { asMovePackage { version module(name: \\\"marker\\\") { functions { nodes { name } } } } } }" | tee "$R/pkg2.json"; echo
gql "{ object(address: \\\"$CAP\\\") { owner { ... on AddressOwner { address { address } } } } }" | tee "$R/capowner.json"; echo
python3 - "$R/pkg2.json" "$R/capowner.json" "$MS" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))["data"]["object"]["asMovePackage"]
fns=[f["name"] for f in p["module"]["functions"]["nodes"]]
assert p["version"]==2 and "upgraded" in fns, (p["version"], fns)
o=json.load(open(sys.argv[2]))["data"]["object"]["owner"]["address"]["address"]
assert o==sys.argv[3], o
print("PASS: version 2 has upgraded(); the UpgradeCap is still owned by the multisig")
PY

echo
echo "SUMMARY publish=$PUB_TX transfer=$XFER_TX fund=${FUND_TX:-none} upgrade=$UP_TX package=$PKG cap=$CAP signers=${SIGNERS[*]}"
rm -rf "$R"
