# lib_v8.sh - shared helpers for the v8 proof scripts. Source it; don't run it.
#
# Every ID comes from deploy/v8/env.v8.sh, which scripts/v8/03_gen_config.sh
# generates from deploy/v8/deployment.env (the single source of truth). The
# nodes (names, IPs, addresses) come from deploy/inventory.tsv; NODES is every
# active node and DAS_NODE the CapToken owner.
#
# Who signs what:
#   node_call rpiN ...  - signed by that node's own key, inside its container
#   pub_call ...        - signed by the publisher, inside WSL (the publisher
#                         key never leaves WSL)
#   pub_read / score    - read-only (object / tx-block / dev-inspect), WSL CLI
#
# Each signing helper prints one line and sets LAST_DIGEST / LAST_STATUS /
# LAST_CODE so a proof can assert on the on-chain outcome. A transaction that
# aborts still has a digest and is on-chain; that is the evidence.
set -o pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
[ -f deploy/v8/env.v8.sh ] || { echo "FATAL: deploy/v8/env.v8.sh missing - run scripts/v8/03_gen_config.sh" >&2; exit 1; }
# shellcheck disable=SC1091
source deploy/v8/env.v8.sh
: "${PKG_V8:?env.v8.sh did not set PKG_V8}"
PKG=$PKG_V8

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_suiom2m}"
GAS_BUDGET="${GAS_BUDGET:-20000000}"
# shellcheck source=../scripts/lib/inventory.sh
. "$REPO/scripts/lib/inventory.sh"; inv_load
mapfile -t NODES < <(inv_nodes active)
DAS_NODE=$(inv_das)
declare -A NODE_IP=() NODE_ADDR=() NODE_CAP=()
for _n in "${NODES[@]}"; do
  _cv="ADMINCAP_${_n^^}"
  NODE_IP[$_n]=${INV_IP[$_n]}; NODE_ADDR[$_n]=${INV_ADDR[$_n]}; NODE_CAP[$_n]=${!_cv:-}
  [ -n "${NODE_CAP[$_n]}" ] || { echo "FATAL: $_cv missing from env.v8.sh - regenerate (scripts/v8/03_gen_config.sh)" >&2; exit 1; }
done

on()      { ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "user@${NODE_IP[$1]}" "${@:2}"; }
wsl_run() { printf '%s\n' "$1" | wsl.exe -d Ubuntu -- bash -s 2>&1 | tr -d '\r'; }
name_of() { local a=${1,,}; for n in "${NODES[@]}"; do [ "${NODE_ADDR[$n],,}" = "$a" ] && { echo "$n"; return; }; done; echo "$1"; }

hr()     { echo "--------------------------------------------------------------------------------"; }
banner() { echo; echo "################################################################################"; echo "#  $*"; echo "################################################################################"; echo; }

# Parse sui CLI output (--json on success; plain "Error executing transaction
# '<digest>' ... with code N" on an abort) into LAST_DIGEST / LAST_STATUS /
# LAST_CODE / LAST_GAS (net MIST = computation + storage - rebate).
_parse_tx() {
  LAST_OUT=$1
  local parsed
  parsed=$(python -c '
import sys,json,re
t=sys.stdin.read(); i=t.find("{")
try:
    d=json.loads(t[i:]) if i>=0 else None
except Exception:
    d=None
if isinstance(d,dict) and "effects" in d:
    e=d["effects"]; st=e.get("status",{}); g=e.get("gasUsed",{})
    net=int(g.get("computationCost",0))+int(g.get("storageCost",0))-int(g.get("storageRebate",0))
    m=re.search(r"\}, (\d+)\)", st.get("error","") or "")
    print("|".join([d.get("digest",""), "success" if st.get("status")=="success" else "abort", m.group(1) if m else "", str(net)]))
else:
    m=re.search(r"Error executing transaction .([1-9A-HJ-NP-Za-km-z]{32,}).", t)
    c=re.search(r"with code (\d+)", t)
    print("|".join([m.group(1) if m else "", "abort" if c else ("failed" if m else "error"), c.group(1) if c else "", ""]))
' <<<"$1")
  IFS='|' read -r LAST_DIGEST LAST_STATUS LAST_CODE LAST_GAS <<<"$parsed"
}
_report() {
  case "$LAST_STATUS" in
    success) echo "    -> Success   digest=$LAST_DIGEST   gas=${LAST_GAS} MIST" ;;
    abort)   echo "    -> MoveAbort code $LAST_CODE   digest=${LAST_DIGEST:-<none>}" ;;
    failed)  echo "    -> execution failed on-chain: $(grep -oE "': [^(]{0,200}" <<<"$LAST_OUT" | head -1 | cut -c4-)  digest=$LAST_DIGEST" ;;
    *)       local why; why=$(grep -oE 'message: "[^"]{0,400}' <<<"$LAST_OUT" | head -1 | cut -c11-)
             [ -n "$why" ] || why=$(grep -vE '^\s*$' <<<"$LAST_OUT" | head -2 | tr '
' ' ' | cut -c1-400)
             echo "    -> rejected before execution (no digest, no gas): $why" ;;
  esac
  [ -n "${PROOF_LOG:-}" ] && printf '%s,%s,%s,%s,%s,%s\n' "$(date -u +%FT%TZ)" "${PROOF_ID:-?}" "$1" "$LAST_STATUS${LAST_CODE:+:$LAST_CODE}" "${LAST_DIGEST:-}" "${LAST_GAS:-}" >> "$PROOF_LOG"
  return 0
}

# The CLI and the node's running plugin spend the same address's gas coins, so
# a CLI tx can be built on a coin version the plugin consumed a moment ago.
# The network refuses it before execution (no gas); rebuild it, as the
# plugin's own withStaleRetry does. Real aborts are never retried.
_stale() { [ "$LAST_STATUS" = error ] && grep -qE "needs to be rebuilt|unavailable for consumption" <<<"$LAST_OUT"; }

# node_call <rpiN> <module> <function> <args...>   (signed by that node)
node_call() {
  local n=$1 m=$2 f=$3 i; shift 3
  echo "\$ [$n] sui client call --package \$PKG_V8 --module $m --function $f --args $*"
  for i in 1 2 3 4; do
    _parse_tx "$(on "$n" "docker exec om2m-active sui client call --package $PKG --module $m --function $f --args $* --gas-budget $GAS_BUDGET --json" 2>&1)"
    _stale || break; echo "    (stale gas-coin version - rebuilding, attempt $((i+1)))"; sleep $((2*i))
  done
  _report "$n:$m::$f"
}

# node_ptb <rpiN> <sui client ptb args...>   (a multi-command PTB, signed by that node)
node_ptb() {
  local n=$1; shift
  echo "\$ [$n] sui client ptb $*" | sed "s/$PKG/\$PKG_V8/g"
  local i; for i in 1 2 3 4; do
    _parse_tx "$(on "$n" "docker exec om2m-active sui client ptb $* --gas-budget $GAS_BUDGET --json" 2>&1)"
    _stale || break; echo "    (stale gas-coin version - rebuilding, attempt $((i+1)))"; sleep $((2*i))
  done
  _report "$n:ptb"
}

# pub_call <module> <function> <args...>   (signed by the publisher in WSL)
pub_call() {
  local m=$1 f=$2; shift 2
  echo "\$ [publisher] sui client call --package \$PKG_V8 --module $m --function $f --args $*"
  _parse_tx "$(wsl_run "sui client call --package $PKG --module $m --function $f --args $* --gas-budget $GAS_BUDGET --json")"
  _report "publisher:$m::$f"
}

# Read-only helpers (no signature).
obj_json() { wsl_run "sui client object $1 --json"; }
tx_json()  { wsl_run "sui client tx-block $1 --json"; }
# dev_inspect <module> <function> <args...> -> first return value as JSON text
# (one retry: a public-endpoint read occasionally fails transiently)
dev_inspect() {
  local m=$1 f=$2 v i; shift 2
  for i in 1 2; do
    v=$(wsl_run "sui client call --package $PKG --module $m --function $f --args $* --dev-inspect --json"       | python -c "import sys,json; d=json.load(sys.stdin); print(d['command_outputs'][0]['returnValues'][0]['json'])" 2>/dev/null) && [ -n "$v" ] && break
    sleep 2
  done
  echo "${v:-?}"
}
score() { dev_inspect trust score_of "$TRUST_REG" "$1" 0x6; }
cluster_field() { obj_json "$CLUSTER" | python -c "import sys,json; print(json.load(sys.stdin)['content']['$1'])"; }
# created_object <digest> <type-suffix> -> object id created by that tx
created_object() {
  tx_json "$1" | python -c "
import sys,json
d=json.load(sys.stdin)
for c in d.get('objectChanges',[]):
    if c.get('type')=='created' and c.get('objectType','').endswith('$2'): print(c['objectId']); break"
}
# expect <label> <status> [code]  - records PASS/FAIL for the proof summary
expect() {
  local want="$2${3:+:$3}" got="$LAST_STATUS${LAST_CODE:+:$LAST_CODE}"
  if [ "$want" = "$got" ]; then echo "    [PASS] $1 (expected $want)"; PROOF_PASS=$((${PROOF_PASS:-0}+1))
  else echo "    [FAIL] $1 (expected $want, got $got)"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1)); fi
}
summary() {
  hr; echo "RESULT: ${PROOF_PASS:-0} assertion(s) held, ${PROOF_FAIL:-0} failed"; hr
  [ "${PROOF_FAIL:-0}" -eq 0 ]
}
# Wait out A12's MIN_INTERVAL_MS (60 s) for a target written at <epoch_s>.
wait_rate_limit() { local left=$(( ${1} + 62 - $(date +%s) )); [ $left -gt 0 ] && { echo "    (waiting ${left}s for the 60 s per-target write interval, A12)"; sleep $left; }; return 0; }
