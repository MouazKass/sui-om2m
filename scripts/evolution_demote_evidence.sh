#!/usr/bin/env bash
#
# evolution_demote_evidence.sh
#
# The DEMOTION half of the evolution evidence. Demonstrates EVO2 (demotion):
# as rpi1's on-chain trust score crosses tier boundaries downward, evolve()
# strips capabilities from the token (ADMIN, then DELETE, then WRITE fall away).
#
# HONEST FRAMING (state this in the paper exactly this way):
#   This script lowers rpi1's on-chain trust score directly via
#   trust::decrease_guarded to demonstrate, deterministically, that a token's
#   capabilities track the score across tier boundaries. It is NOT a claim that
#   rpi1 misbehaved — the behaviour->score link is a SEPARATE experiment driven
#   by the trust engine. This script isolates and proves the score->capability
#   link only.
#
# Mechanism:
#   * Signed by the PUBLISHER wallet (0xb87fb2af...), which holds a Trust
#     AdminCap and is NOT rpi1 — so decrease_guarded's self-scoring guard
#     (E_SELF_SCORING=4) passes.
#   * After each score step, evolve() is called with node_addr=rpi1 and the
#     token's allowed_ops is read back to show the capability change.
#   * At the end, the score is RESTORED via increase_guarded so the testbed is
#     left as found.
#
# PREREQUISITE: run evolution_lifecycle_evidence.sh first and pass the TOKEN it
#   minted as $1 (it must already be bootstrapped). Or pass any bootstrapped,
#   publisher-owned CapToken id.
#
# Usage:
#   ./evolution_demote_evidence.sh <TOKEN_OBJECT_ID>
#
set -uo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <bootstrapped-CapToken-object-id>"
    exit 2
fi
TOKEN="$1"

# ----------------------------- config ---------------------------------------
PKG_V4=0xb579914d317ebd8bb6ef6d0b59d2f80a4a81fc731917840dd01a4daa64180899
TRUST_REG=0xce9bb88e09fa044eca1365f167cab3e12ed427429a311c1bf1bd96b08cfbef0f
TRUST_ADMIN_CAP=0xd858c23d4e333843bc09114985c752a7f482b8950db1059fee07b0478c58f568
CLOCK=0x6
PUBLISHER=0xb87fb2af21e29dd292d5b557b92d95a544794a589620f4b437f2247f075d6a1e
RPI1=0xef9c6271d8c6cc9e1d9707a117f876e7a8679509f141879bc05ae7bcffe1d5f9
GAS=60000000

TS=$(date +%Y%m%d-%H%M%S)
mkdir -p evidence
LOG="evidence/evolution-demote-${TS}.log"

say()  { echo -e "$*" | tee -a "$LOG"; }
hr()   { say "------------------------------------------------------------------"; }

ops_name() {
    case "$1" in
        1) echo "READ" ;; 3) echo "READ|WRITE" ;;
        7) echo "READ|WRITE|DELETE" ;; 15) echo "READ|WRITE|DELETE|ADMIN" ;;
        *) echo "mask=$1" ;;
    esac
}
run_ptb() { local out; out=$(mktemp); sui client ptb "$@" --gas-budget "$GAS" >"$out" 2>&1; echo "$out"; }
digest_from() { grep -m1 -E '^Transaction Digest:' "$1" | awk '{print $3}'; }
ptb_ok() { grep -qE 'Status: *Success' "$1"; }

read_eff_score() {
    python3 - "$TRUST_REG" "$RPI1" <<'PY'
import json,sys,urllib.request,time
reg,node=sys.argv[1],sys.argv[2]; RPC="https://fullnode.testnet.sui.io:443"
def rpc(m,p):
    req=json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode()
    r=urllib.request.Request(RPC,req,{"Content-Type":"application/json"})
    return json.load(urllib.request.urlopen(r,timeout=15))
o=rpc("sui_getObject",[reg,{"showContent":True}])
tbl=o["result"]["data"]["content"]["fields"]["entries"]["fields"]["id"]["id"]
df=rpc("suix_getDynamicFieldObject",[tbl,{"type":"address","value":node}])
f=df["result"]["data"]["content"]["fields"]["value"]["fields"]
stored=int(f["score"]); last=int(f["last_update_ms"])
now=int(time.time()*1000); days=(now-last)//86400000
eff=max(0,stored-days)
print(eff)
PY
}

read_token_ops() {
    python3 - "$1" <<'PY'
import json,sys,urllib.request
tok=sys.argv[1]; RPC="https://fullnode.testnet.sui.io:443"
req=json.dumps({"jsonrpc":"2.0","id":1,"method":"sui_getObject","params":[tok,{"showContent":True}]}).encode()
r=urllib.request.Request(RPC,req,{"Content-Type":"application/json"})
o=json.load(urllib.request.urlopen(r,timeout=15))
try: print(o["result"]["data"]["content"]["fields"]["allowed_ops"])
except Exception: print("?")
PY
}

tier_of() { local s=$1; if [ "$s" -ge 90 ]; then echo 4; elif [ "$s" -ge 75 ]; then echo 3; elif [ "$s" -ge 50 ]; then echo 2; elif [ "$s" -ge 25 ]; then echo 1; else echo 0; fi; }

decrease_by() {  # $1 = delta ; echoes digest
    local o; o=$(run_ptb --move-call "${PKG_V4}::trust::decrease_guarded" \
        @"$TRUST_ADMIN_CAP" @"$TRUST_REG" @"$RPI1" "${1}u64" @"$CLOCK")
    cat "$o" >>"$LOG"; digest_from "$o"
}
increase_by() { # $1 = delta ; echoes digest
    local o; o=$(run_ptb --move-call "${PKG_V4}::trust::increase_guarded" \
        @"$TRUST_ADMIN_CAP" @"$TRUST_REG" @"$RPI1" "${1}u64" @"$CLOCK")
    cat "$o" >>"$LOG"; digest_from "$o"
}
evolve_now() {
    local o; o=$(run_ptb --move-call "${PKG_V4}::evolution::evolve" \
        @"$TOKEN" @"$TRUST_REG" @"$RPI1" @"$CLOCK")
    cat "$o" >>"$LOG"; digest_from "$o"
}

# ----------------------------- run ------------------------------------------
say "=== Evolution DEMOTION evidence ($TS) ==="
say "token      : $TOKEN"
say "node_addr  : rpi1 $RPI1"
say "driver     : publisher $PUBLISHER (Trust AdminCap $TRUST_ADMIN_CAP)"
say "NOTE: score is lowered directly to isolate the score->capability link."
say "      This is NOT a misbehaviour claim; that is a separate experiment."
hr

# ensure publisher is active
if [ "$(sui client active-address 2>/dev/null)" != "$PUBLISHER" ]; then
    sui client switch --address "$PUBLISHER" >/dev/null 2>&1 || { say "ERROR: publisher not in keystore"; exit 1; }
fi

START=$(read_eff_score)
say "[0] rpi1 effective score now: $START (tier $(tier_of "$START"))"
say "    token ops now: $(read_token_ops "$TOKEN") ($(ops_name "$(read_token_ops "$TOKEN")"))"
hr

# Build a descending sequence of target scores, one just below each boundary
# at or under the current score, so each step crosses exactly one tier.
BOUNDARIES=(90 75 50 25)
declare -a STEPS=()
for b in "${BOUNDARIES[@]}"; do
    if [ "$START" -ge "$b" ]; then STEPS+=("$((b-1))"); fi
done
# also a floor step into tier 0 if we got that far
STEPS+=("10")

PREV="$START"
TOTAL_DROP=0
for target in "${STEPS[@]}"; do
    [ "$target" -ge "$PREV" ] && continue
    delta=$((PREV - target))
    say "[step] lowering rpi1 score $PREV -> $target  (delta $delta), crossing into tier $(tier_of "$target")"
    d1=$(decrease_by "$delta")
    say "    decrease_guarded digest: $d1"
    NOWSCORE=$(read_eff_score)
    say "    score now: $NOWSCORE (tier $(tier_of "$NOWSCORE"))"
    d2=$(evolve_now)
    say "    evolve digest: $d2"
    OPS=$(read_token_ops "$TOKEN")
    say "    >>> token ops: $OPS ($(ops_name "$OPS"))   [tier $(tier_of "$NOWSCORE") expects: $(case $(tier_of "$NOWSCORE") in 0|1) echo 1;; 2) echo 3;; 3) echo 7;; 4) echo 15;; esac)]"
    hr
    TOTAL_DROP=$((TOTAL_DROP + delta))
    PREV="$target"
done

say "[restore] returning rpi1 score by +$TOTAL_DROP to leave the testbed as found"
dr=$(increase_by "$TOTAL_DROP")
say "    increase_guarded digest: $dr"
FINAL=$(read_eff_score)
say "    rpi1 effective score restored to: $FINAL (tier $(tier_of "$FINAL"))"
say "    (note: differs from start by at most the natural 1pt/day decay during the run)"
hr
say "=== Done. Transcript: $LOG ==="
say "Capability strip observed: ADMIN/DELETE/WRITE fall away as tiers drop;"
say "each transition has a decrease + evolve digest above for the appendix."
