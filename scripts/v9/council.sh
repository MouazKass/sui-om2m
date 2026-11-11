#!/usr/bin/env bash
# council.sh - operate the v9 k-of-n council from its member nodes.
#
# Run from Git Bash on the laptop. Every transaction is signed ON the member
# Pi, by that node's own key, through the sui CLI inside its om2m-active
# container (the same path the proofs use); no key ever leaves a node. Each
# proposal/approval also presents that node's own trust AdminCap
# (TRUST_ADMIN_CAP_<NAME> in deploy/v8/deployment.env), as quorum.move requires.
#
#   council.sh status   [<proposal-id>]                  threshold, members, (approvals of a proposal)
#   council.sh propose  <node> <action> [target] [text] [value] [value2] [value3] [ttl_ms]
#                       action: add-member remove-member set-threshold
#                               trust-grant-admin trust-revoke-admin trust-add-node
#                               id-register id-deregister
#                               policy-set policy-remove policy-add-blackout policy-clear-blackouts
#                               policy-bind-device policy-unbind-device policy-add-reader policy-remove-reader  (v10)
#                               token-mint cluster-set-gate   (or the numeric ACT_* id)
#   council.sh approve  <node> <proposal-id>
#   council.sh execute  <node> <proposal-id>             picks execute_<kind> from the proposal's action
#                       (membership, trust, identity, policy, mint, cluster)
#
# Argument meaning per action (quorum.move): token-mint target=owner text=resource
# value=expiry_ms value2=max_uses value3=ops; policy-set text=resource value=min_trust
# value2=ops mask; id-register target text=cse_id value=role; cluster-set-gate
# target=cluster value=gate; trust-revoke-admin target=cap id; policy-bind-device
# text=resource target=device; policy-add-reader/remove-reader text=resource target=reader.
#
# Defaults: target 0x0 (the zero address), text "", values 0, ttl 24 h (quorum.move caps it at 7 days).
# Every call is simulated first (dev-inspect, free) and only submitted if it
# would succeed; a stale gas-coin version is rebuilt and retried.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
[ -n "${COUNCIL:-}" ] || die "no COUNCIL in $V9_ENV: run scripts/v9/04_council.sh --execute first"
[ -n "${PKG_V9:-}" ] || die "no PKG_V9 in $V9_ENV"
# Always call the NEWEST package. Old package versions stay callable on Sui,
# and their bodies do not know later rules: e.g. v9's policy::set_policy would
# put a v10 device-bound resource's policy back into the plain table, where
# the v8/v9 `evaluate` can grant it without the device check.
CALL_PKG="${PKG_V10:-$PKG_V9}"
CMD="${1:-status}"; shift || true
GAS=30000000
CLOCK=0x6

node_ssh() { ssh -F "$INV_SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=10 "${INV_IP[$1]}" "${@:2}"; }

# The council stores the action as u8; keep these in step with quorum.move.
act_id() {
  case "$1" in
    add-member) echo 1;; remove-member) echo 2;; set-threshold) echo 3;;
    trust-grant-admin) echo 10;; trust-revoke-admin) echo 11;; trust-add-node) echo 12;;
    id-register) echo 20;; id-deregister) echo 21;;
    policy-set) echo 30;; policy-remove) echo 31;; policy-add-blackout) echo 32;; policy-clear-blackouts) echo 33;;
    policy-bind-device) echo 34;; policy-unbind-device) echo 35;; policy-add-reader) echo 36;; policy-remove-reader) echo 37;;
    token-mint) echo 40;; cluster-set-gate) echo 50;;
    [0-9]*) echo "$1";;
    *) die "unknown action '$1'";;
  esac
}
grep -q "const ACT_CLUSTER_SET_GATE: u8 = 50;" "$REPO/move/sources/quorum.move" || die "quorum.move action ids changed; update act_id()"
grep -q "const ACT_POLICY_REMOVE_READER: u8 = 37;" "$REPO/move/sources/quorum.move" || die "quorum.move v10 action ids changed; update act_id()"

# member <name>: check the node is active, a council member and holds a recorded cap.
member() {
  inv_require "$1"
  [ "${INV_STATUS[$1]}" = active ] || die "$1 is ${INV_STATUS[$1]}, not active"
  [ -n "$(node_cap "$1")" ] || die "$1 has no $(inv_cap_var "$1") recorded"
}

# node_call <name> <function> <args...>: run quorum::<function> signed by <name>.
# Prints the CLI JSON on stdout. Simulates first; retries on a stale gas coin.
node_call() {
  local n=$1 fn=$2; shift 2
  local args="$*" i out
  local base="sui client call --package $CALL_PKG --module quorum --function $fn --args $args --gas-budget $GAS"
  out=$(node_ssh "$n" "docker exec om2m-active $base --dev-inspect" 2>&1) || true
  if ! grep -q "execution status: success\|\"status\": \"success\"" <<<"$out"; then
    echo "$out" | grep -E "MoveAbort|Error|error" | head -3 >&2
    die "simulation of quorum::$fn by $n would fail; nothing submitted"
  fi
  for i in 1 2 3 4; do
    out=$(node_ssh "$n" "docker exec om2m-active $base --json" 2>&1) || true
    if grep -qE "needs to be rebuilt|unavailable for consumption" <<<"$out"; then
      echo "  (stale gas-coin version, rebuilding: attempt $((i+1)))" >&2; sleep $((2*i)); continue
    fi
    break
  done
  printf '%s\n' "$out"
}

# tx_summary: read CLI JSON on stdin; print "digest status" and fail unless success.
tx_summary() {
  python3 -c '
import json,sys
t=sys.stdin.read(); s=t[t.find("{"):]
try: d=json.loads(s)
except Exception: sys.exit("FATAL: no JSON from the CLI:\n"+t[:600])
st=(d.get("effects") or {}).get("status") or {}
print(d.get("digest","?"), st.get("status","?"), st.get("error",""))
for e in d.get("events",[]):
    pj=e.get("parsedJson") or {}
    if e.get("type","").endswith("::quorum::Proposed"):  print("proposal_id", pj.get("proposal_id"))
    if e.get("type","").endswith("::quorum::Approved"):  print("approvals", pj.get("approvals"))
    if e.get("type","").endswith("::quorum::Executed"):  print("executed action", pj.get("action"))
for c in d.get("objectChanges",[]):
    if c.get("type")=="created" and c.get("objectType","").endswith("::cap_token::CapToken"):
        print("created CapToken", c.get("objectId"))
sys.exit(0 if st.get("status")=="success" else 1)'
}

# submit <node> <function> <args...>: node_call, then summarise; a refused simulation
# stops here with its reason (nothing was submitted).
submit() { local out; out=$(node_call "$@") || exit 1; printf '%s
' "$out" | tx_summary; }

# proposal_action <pid>: the action id stored in the proposal (dynamic table entry).
proposal_action() {
  local pid=$1
  curl -sS --max-time 20 "$GRAPHQL_URL" -H 'content-type: application/json' \
    -d "{\"query\":\"{ object(address: \\\"$COUNCIL\\\") { asMoveObject { contents { json } } } }\"}" \
  | python3 -c '
import json,sys
d=json.load(sys.stdin)
c=d["data"]["object"]["asMoveObject"]["contents"]["json"]
print(c["proposals"]["id"])' > /tmp/council_tbl.$$
  local tbl; tbl=$(cat /tmp/council_tbl.$$); rm -f /tmp/council_tbl.$$
  curl -sS --max-time 20 "$GRAPHQL_URL" -H 'content-type: application/json' \
    -d "{\"query\":\"{ address(address: \\\"$tbl\\\") { dynamicField(name: {type: \\\"u64\\\", bcs: \\\"$(python3 -c "import base64,struct,sys;print(base64.b64encode(struct.pack('<Q',int(sys.argv[1]))).decode())" "$pid")\\\"}) { value { ... on MoveValue { json } } } } }\"}" \
  | python3 -c '
import json,sys
d=json.load(sys.stdin)
f=((d.get("data") or {}).get("address") or {}).get("dynamicField")
if not f: sys.exit("FATAL: no such proposal (executed, discarded, or wrong id)")
print(f["value"]["json"]["action"])'
}

case "$CMD" in
  status)
    # The reads use the sui CLI (dev-inspect), which lives in WSL; re-run there from Git Bash.
    if [ -z "$SUI" ] || [ ! -x "$SUI" ]; then
      rw=$(printf '%s' "$REPO" | sed -E 's#^/([a-zA-Z])/#/mnt/\L\1/#')
      exec wsl.exe -d Ubuntu -- bash -lc "cd '$rw' && bash scripts/v9/council.sh status ${1:-}"
    fi
    echo "council   $COUNCIL"
    echo "threshold $(inspect_value "$CALL_PKG" quorum threshold "$COUNCIL")  members $(inspect_value "$CALL_PKG" quorum member_count "$COUNCIL")"
    for n in "${V9_NODES[@]}"; do
      echo "  $n ${INV_ADDR[$n]:0:10}… member=$(inspect_value "$CALL_PKG" quorum is_member "$COUNCIL" "${INV_ADDR[$n]}") cap_valid=$(inspect_value "$CALL_PKG" trust is_cap_valid "$TRUST_REG" "$(node_cap "$n")")"
    done
    if [ -n "${1:-}" ]; then
      echo "proposal $1: exists=$(inspect_value "$CALL_PKG" quorum has_proposal "$COUNCIL" "$1") approvals=$(inspect_value "$CALL_PKG" quorum approval_count "$COUNCIL" "$1")"
    fi
    ;;

  propose)
    n="${1:?node}"; act=$(act_id "${2:?action}"); member "$n"
    target="${3:-0x0000000000000000000000000000000000000000000000000000000000000000}"; [ "$target" = 0x0 ] && target=0x0000000000000000000000000000000000000000000000000000000000000000; text="${4:-}"; v1="${5:-0}"; v2="${6:-0}"; v3="${7:-0}"; ttl="${8:-86400000}"
    say "propose action $act by $n (target $target, text '$text', values $v1/$v2/$v3, ttl ${ttl} ms)"
    submit "$n" propose "$COUNCIL" "$(node_cap "$n")" "$TRUST_REG" "$act" "$target" "'\"$text\"'" "$v1" "$v2" "$v3" "$ttl" "$CLOCK"
    ;;

  approve)
    n="${1:?node}"; pid="${2:?proposal-id}"; member "$n"
    say "approve proposal $pid by $n"
    submit "$n" approve "$COUNCIL" "$pid" "$(node_cap "$n")" "$TRUST_REG" "$CLOCK"
    ;;

  execute)
    n="${1:?node}"; pid="${2:?proposal-id}"; member "$n"
    act=$(proposal_action "$pid")
    say "execute proposal $pid (action $act) by $n"
    case "$act" in
      1|2|3)   submit "$n" execute_membership "$COUNCIL" "$pid" "$ID_REG" "$TRUST_REG" "$CLOCK";;
      10|11|12) submit "$n" execute_trust   "$COUNCIL" "$pid" "$TRUST_REG" "$CLOCK";;
      20|21)   submit "$n" execute_identity "$COUNCIL" "$pid" "$ID_REG" "$TRUST_REG" "$CLOCK";;
      30|31|32|33|34|35|36|37) submit "$n" execute_policy "$COUNCIL" "$pid" "${POLICY_REG:?POLICY_REG missing from deployment.env}" "$TRUST_REG" "$CLOCK";;
      40)      submit "$n" execute_mint     "$COUNCIL" "$pid" "$TRUST_REG" "$CLOCK";;
      50)      submit "$n" execute_cluster  "$COUNCIL" "$pid" "$CLUSTER" "$TRUST_REG" "$CLOCK";;
      *) die "unknown action $act in proposal $pid";;
    esac
    ;;

  *) sed -n '2,22p' "$0"; exit 1;;
esac
