#!/usr/bin/env bash
# rehearse_multisig.sh - exercise 00_multisig.sh and '02_upgrade.sh combine'
# end to end with THREE THROWAWAY keys, before any real signer is involved.
#
#   scripts/v9/rehearse_multisig.sh
#
# Everything happens in a temp dir: a temp keystore, a temp V9_DIR. Nothing is
# executed on-chain and nothing touches ~/.sui or deploy/v9. The only network
# use is serializing one unsigned 1-MIST self-payment from the active address,
# to get real TransactionData bytes to sign (it is never signed by that address
# and never submitted).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
require_cli

T=$(mktemp -d /tmp/v9-rehearse.XXXXXX); trap 'rm -rf "$T"' EXIT
KS="$T/ks.keystore"; export V9_DIR="$T/v9"; mkdir -p "$V9_DIR"
pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass+1)); }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
expect_fail() { local what="$1"; shift; if "$@" >"$T/out" 2>&1; then bad "$what (was accepted)"; cat "$T/out"; else ok "$what -> $(grep -m1 FATAL "$T/out" || tail -1 "$T/out")"; fi; }

say "three throwaway signers"
PKS=(); ADDRS=()
for i in 1 2 3; do
  j=$(cd "$T" && "$SUI" keytool --keystore-path "$KS" --json generate ed25519 2>/dev/null)
  PKS+=("$(printf '%s' "$j" | python3 -c 'import json,sys; print(json.load(sys.stdin)["publicBase64Key"])')")
  m=$(printf '%s' "$j" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mnemonic"])')
  ADDRS+=("$("$SUI" keytool --keystore-path "$KS" --json import "$m" ed25519 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["suiAddress"])')")
done
printf '  %s\n' "${PKS[@]}"

say "00_multisig.sh"
bash "$HERE/00_multisig.sh" "${PKS[@]}" > "$T/ms.out" && ok "derive + record" || { bad "derive"; cat "$T/ms.out"; }
. "$V9_DIR/multisig.env"
want=$("$SUI" keytool --json multi-sig-address --pks "${PKS[@]}" --weights 1 1 1 --threshold 2 | python3 -c 'import json,sys; print(json.load(sys.stdin)["multisigAddress"])')
[ "$UPGRADE_MULTISIG" = "$want" ] && ok "recorded address = CLI-derived $want" || bad "address mismatch $UPGRADE_MULTISIG vs $want"
bash "$HERE/00_multisig.sh" "${PKS[@]}" | grep -q "nothing to do" && ok "re-run is a no-op" || bad "re-run not idempotent"
expect_fail "duplicate key refused"      bash "$HERE/00_multisig.sh" "${PKS[0]}" "${PKS[0]}" "${PKS[2]}"
expect_fail "threshold 1 refused"        bash "$HERE/00_multisig.sh" "${PKS[@]}" 1
expect_fail "non-ed25519 blob refused"   bash "$HERE/00_multisig.sh" "${PKS[0]}" "${PKS[1]}" "AAAA"
expect_fail "only two keys refused"      bash "$HERE/00_multisig.sh" "${PKS[0]}" "${PKS[1]}"

say "real TransactionData to sign (serialized, never submitted)"
me=$("$SUI" client active-address)
coin=$("$SUI" client gas --json | python3 -c 'import json,sys; g=json.load(sys.stdin); g=g["gasCoins"] if isinstance(g,dict) else g; print(g[0]["gasCoinId"])')
"$SUI" client pay-sui --input-coins "$coin" --recipients "$me" --amounts 1 --gas-budget 5000000 \
  --serialize-unsigned-transaction | tail -1 | tr -d '[:space:]' > "$V9_DIR/upgrade.tx.b64"
[ -s "$V9_DIR/upgrade.tx.b64" ] && ok "tx bytes ($(wc -c < "$V9_DIR/upgrade.tx.b64") chars)" || bad "no tx bytes"
TX=$(cat "$V9_DIR/upgrade.tx.b64")
sig() { "$SUI" keytool --keystore-path "$KS" --json sign --address "$1" --data "$TX" | python3 -c 'import json,sys; print(json.load(sys.stdin)["suiSignature"])'; }
S1=$(sig "${ADDRS[0]}"); S3=$(sig "${ADDRS[2]}")

say "02_upgrade.sh combine"
# deliberately pasted out of order (3 then 1): combine must reorder them
bash "$HERE/02_upgrade.sh" combine "$S3" "$S1" > "$T/c.out" 2>&1 && ok "combine (sigs given out of order)" || { bad "combine"; cat "$T/c.out"; }
[ -s "$V9_DIR/upgrade.multisig" ] && ok "multisig signature written" || bad "no multisig file"
if "$SUI" keytool --json decode-multi-sig --multisig "$(cat "$V9_DIR/upgrade.multisig")" > "$T/dec" 2>&1; then
  python3 - "$T/dec" "$UPGRADE_MULTISIG" "${PKS[0]}" "${PKS[2]}" <<'PY' && ok "decoded: signers 1 and 3 in key order, threshold 2, address matches" || bad "decode mismatch"
import json,sys
d=json.load(open(sys.argv[1]))
assert d["multisigAddress"]==sys.argv[2], ("address", d["multisigAddress"])
assert d["threshold"]==2 and len(d["pubKeys"])==3, "shape"
got=[p["publicBase64Key"] for p in d["participatingKeysSignatures"]]
assert got==[sys.argv[3], sys.argv[4]], ("participants", got)
PY
else bad "decode-multi-sig failed: $(tail -1 "$T/dec")"; fi
expect_fail "single signature refused"   bash "$HERE/02_upgrade.sh" combine "$S1"
expect_fail "same signer twice refused"  bash "$HERE/02_upgrade.sh" combine "$S1" "$S1"
OUT_KS="$T/outsider.keystore"
oj=$(cd "$T" && "$SUI" keytool --keystore-path "$OUT_KS" --json generate ed25519 2>/dev/null)
om=$(printf '%s' "$oj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mnemonic"])')
oa=$("$SUI" keytool --keystore-path "$OUT_KS" --json import "$om" ed25519 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["suiAddress"])')
SO=$("$SUI" keytool --keystore-path "$OUT_KS" --json sign --address "$oa" --data "$TX" | python3 -c 'import json,sys; print(json.load(sys.stdin)["suiSignature"])')
expect_fail "non-member signature refused" bash "$HERE/02_upgrade.sh" combine "$S1" "$SO"

echo
echo "rehearsal: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
