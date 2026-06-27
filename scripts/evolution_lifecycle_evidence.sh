#!/usr/bin/env bash
#
# evolution_lifecycle_evidence.sh  (sui 1.73.0 compatible)
#
# Token lifecycle (mint -> validate -> [evolve/demote] -> revoke) + evolution
# evidence against deployed v4. Parses sui client ptb TEXT output (the --json
# flag is unreliable on 1.73.0).
#
# Single wallet: publisher 0xb87fb2af... owns IssuerCap + the demo token.
# evolve() uses node_addr=rpi1 so it tracks rpi1's real decayed score.
#
# IMPORTANT ORDERING: this script does NOT revoke by default, because you may
# want to run the demotion script on the same token first. Pass --revoke to
# revoke at the end, or run the revoke step manually / via the demote script's
# guidance after you've captured the demotion evidence.
#
# Non-destructive to production: mints a FRESH token; never touches 0xef3e0c....

set -uo pipefail
DO_REVOKE=0
[ "${1:-}" = "--revoke" ] && DO_REVOKE=1

PKG_V4=0xb579914d317ebd8bb6ef6d0b59d2f80a4a81fc731917840dd01a4daa64180899
ISSUER_CAP=0x16bd474d07368b6d2fb848ae0050c3cc031d0529593699b31aca59f95f319860
TRUST_REG=0xce9bb88e09fa044eca1365f167cab3e12ed427429a311c1bf1bd96b08cfbef0f
CLOCK=0x6
PUBLISHER=0xb87fb2af21e29dd292d5b557b92d95a544794a589620f4b437f2247f075d6a1e
RPI1=0xef9c6271d8c6cc9e1d9707a117f876e7a8679509f141879bc05ae7bcffe1d5f9
RES='/in-cse/in-name/evo-demo-cnt'
EXPIRY_MS=9000000000000
MAX_USES=1000
GAS=60000000

TS=$(date +%Y%m%d-%H%M%S)
mkdir -p evidence
LOG="evidence/evolution-${TS}.log"

say()  { echo -e "$*" | tee -a "$LOG"; }
hr()   { say "------------------------------------------------------------------"; }
ops_name() { case "$1" in 1) echo READ;; 3) echo "READ|WRITE";; 7) echo "READ|WRITE|DELETE";; 15) echo "READ|WRITE|DELETE|ADMIN";; *) echo "mask=$1";; esac; }

run_ptb() { local out; out=$(mktemp); sui client ptb "$@" --gas-budget "$GAS" >"$out" 2>&1; echo "$out"; }
digest_from() { grep -m1 -E '^Transaction Digest:' "$1" | awk '{print $3}'; }
token_from()  {
    # Capture hex ONLY from ID:/ObjectID: lines (never the ObjectType line,
    # which contains the package id), print when we reach the CapToken type.
    awk '
      /ID:/ && match($0, /0x[0-9a-f]{64}/) { last=substr($0,RSTART,RLENGTH) }
      /ObjectType:.*cap_token::CapToken/ { print last; exit }
    ' "$1"
}
ptb_ok()      { grep -qE 'Status: *Success' "$1"; }

read_token_ops() {
    python3 - "$1" <<'PY'
import json,sys,urllib.request
tok=sys.argv[1]; RPC="https://fullnode.testnet.sui.io:443"
req=json.dumps({"jsonrpc":"2.0","id":1,"method":"sui_getObject","params":[tok,{"showContent":True}]}).encode()
r=urllib.request.Request(RPC,req,{"Content-Type":"application/json"})
try:
    o=json.load(urllib.request.urlopen(r,timeout=15))
    print(o["result"]["data"]["content"]["fields"]["allowed_ops"])
except Exception: print("?")
PY
}

read_rpi1() {
    python3 - "$TRUST_REG" "$RPI1" <<'PY'
import json,sys,urllib.request,time
reg,node=sys.argv[1],sys.argv[2]; RPC="https://fullnode.testnet.sui.io:443"
def rpc(m,p):
    req=json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode()
    r=urllib.request.Request(RPC,req,{"Content-Type":"application/json"})
    return json.load(urllib.request.urlopen(r,timeout=15))
try:
    o=rpc("sui_getObject",[reg,{"showContent":True}])
    tbl=o["result"]["data"]["content"]["fields"]["entries"]["fields"]["id"]["id"]
    df=rpc("suix_getDynamicFieldObject",[tbl,{"type":"address","value":node}])
    f=df["result"]["data"]["content"]["fields"]["value"]["fields"]
    stored=int(f["score"]); last=int(f["last_update_ms"])
    now=int(time.time()*1000); days=(now-last)//86400000
    eff=max(0,stored-days)
    tier=4 if eff>=90 else 3 if eff>=75 else 2 if eff>=50 else 1 if eff>=25 else 0
    print(stored,eff,tier)
except Exception:
    print("ERR 0 0")
PY
}
exp_ops_for_tier() { case "$1" in 0|1) echo 1;; 2) echo 3;; 3) echo 7;; 4) echo 15;; esac; }

say "=== Evolution + Token-Lifecycle Evidence Run ($TS) ==="
say "package v4 : $PKG_V4"
say "driver     : publisher $PUBLISHER"
say "node_addr  : rpi1 $RPI1"
[ "$DO_REVOKE" = 1 ] && say "mode       : will REVOKE at end" || say "mode       : will NOT revoke (run demotion first, revoke later)"
hr

if [ "$(sui client active-address 2>/dev/null)" != "$PUBLISHER" ]; then
    sui client switch --address "$PUBLISHER" >/dev/null 2>&1 || { say "ERROR: publisher not in keystore"; exit 1; }
fi

say "[0] rpi1 score..."
read RPI1_STORED RPI1_EFF RPI1_TIER <<<"$(read_rpi1)"
EXP=$(exp_ops_for_tier "$RPI1_TIER")
say "    stored=$RPI1_STORED effective=$RPI1_EFF tier=$RPI1_TIER -> evolve target ops=$EXP ($(ops_name "$EXP"))"
hr

say "[1] MINT fresh CapToken (READ) [CT2 issuance]"
O=$(run_ptb --move-call "${PKG_V4}::cap_token::mint" \
      @"$ISSUER_CAP" @"$PUBLISHER" "\"$RES\"" 1u8 "${EXPIRY_MS}u64" "${MAX_USES}u64")
cat "$O" >>"$LOG"
if ! ptb_ok "$O"; then say "ERROR: mint failed; see $LOG"; sed -n '1,40p' "$O"; exit 1; fi
TOKEN=$(token_from "$O"); MINT_DIG=$(digest_from "$O")
say "    token  = $TOKEN"
say "    digest = $MINT_DIG"
O1=$(read_token_ops "$TOKEN"); say "    ops    = $O1 ($(ops_name "$O1")) [expect 1 READ]"
hr

say "[2] VALIDATE (READ) [CT3/CT4]"
O=$(run_ptb --move-call "${PKG_V4}::cap_token::validate_for_use" \
      @"$TOKEN" "\"$RES\"" 1u8 @"$CLOCK")
cat "$O" >>"$LOG"
ptb_ok "$O" && say "    digest = $(digest_from "$O")  [use-count +1]" || say "    NOTE: validate failed (see log)"
hr

say "[3] BOOTSTRAP"
O=$(run_ptb --move-call "${PKG_V4}::evolution::bootstrap" @"$TOKEN" @"$CLOCK")
cat "$O" >>"$LOG"
ptb_ok "$O" && say "    digest = $(digest_from "$O")" || { say "ERROR: bootstrap failed"; exit 1; }
hr

say "[4] EVOLVE at rpi1 tier $RPI1_TIER [EVO1/EVO2]"
O=$(run_ptb --move-call "${PKG_V4}::evolution::evolve" \
      @"$TOKEN" @"$TRUST_REG" @"$RPI1" @"$CLOCK")
cat "$O" >>"$LOG"
ptb_ok "$O" && say "    digest = $(digest_from "$O")" || say "    NOTE: evolve failed (see log)"
OPS=$(read_token_ops "$TOKEN")
say "    ops    = $OPS ($(ops_name "$OPS")) [expect $EXP $(ops_name "$EXP")]"
[ "$OPS" = "$EXP" ] && say "    >>> PASS: READ -> $(ops_name "$OPS") autonomously (rpi1 tier $RPI1_TIER)" \
                     || say "    >>> CHECK: got $OPS expected $EXP"
hr

say "[5] EVOLVE again (idempotent) [EVO3]"
O=$(run_ptb --move-call "${PKG_V4}::evolution::evolve" \
      @"$TOKEN" @"$TRUST_REG" @"$RPI1" @"$CLOCK")
cat "$O" >>"$LOG"
ptb_ok "$O" && say "    digest = $(digest_from "$O")" || say "    NOTE: 2nd evolve failed"
OPS2=$(read_token_ops "$TOKEN")
[ "$OPS2" = "$OPS" ] && say "    >>> PASS: ops unchanged ($OPS2)" || say "    >>> CHECK: ops changed to $OPS2"
hr

say "TOKEN for demotion: $TOKEN"
say "Next: ./scripts/evolution_demote_evidence.sh $TOKEN   (strips DELETE/WRITE as score drops, then restores)"
hr

if [ "$DO_REVOKE" = 1 ]; then
    say "[6] REVOKE [CT5]"
    O=$(run_ptb --move-call "${PKG_V4}::cap_token::revoke" @"$ISSUER_CAP" @"$TOKEN")
    cat "$O" >>"$LOG"
    ptb_ok "$O" && say "    digest = $(digest_from "$O")" || say "    NOTE: revoke failed (see log)"
    GONE=$(python3 - "$TOKEN" <<'PY'
import json,sys,urllib.request
tok=sys.argv[1]; RPC="https://fullnode.testnet.sui.io:443"
req=json.dumps({"jsonrpc":"2.0","id":1,"method":"sui_getObject","params":[tok,{"showType":True}]}).encode()
r=urllib.request.Request(RPC,req,{"Content-Type":"application/json"})
o=json.load(urllib.request.urlopen(r,timeout=15))
print("DELETED" if o.get("result",{}).get("error") else "STILL-EXISTS")
PY
)
    say "    object status: $GONE [expect DELETED]"
    hr
else
    say "[6] REVOKE skipped (no --revoke). Token left alive for demotion."
    say "    To revoke later:"
    say "      sui client ptb --move-call ${PKG_V4}::cap_token::revoke @$ISSUER_CAP @$TOKEN --gas-budget $GAS"
    hr
fi

say "=== Done. Transcript: $LOG ==="
say "Summary: mint=$MINT_DIG  token=$TOKEN  evolve_ops=$(ops_name "$OPS")"
