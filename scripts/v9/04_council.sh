#!/usr/bin/env bash
# 04_council.sh - V9_DESIGN.md phase G: arm k-of-n governance. ONE-WAY.
#
#   scripts/v9/04_council.sh            # DRY RUN (default): preconditions + free simulations
#   scripts/v9/04_council.sh --execute  # create the Council, then hand it the caps
#
# Run in WSL as the publisher, AFTER phase F is verified (03_switch_plugin.sh v9
# recorded V9_GRANT_VERIFIED). Once the Council exists:
#   - no single trust AdminCap can revoke a peer, grant caps or add nodes;
#   - every v8-package cap path aborts (E_CAP_REVOKED), so the plugin must
#     already be calling v9;
#   - registering nodes / minting tokens / policy writes become k-of-n proposals.
#
# Members = every status=active node in deploy/inventory.tsv; k defaults to the
# strict majority (3 of 5). Override with THRESHOLD=k (quorum.move still enforces
# 2k > n and k >= 2). Each member must already hold its own valid trust AdminCap:
# proposing and approving require it.
# Undoing it needs a multisig upgrade (V9_DESIGN.md I). Idempotent: a step whose
# effect is already on-chain is skipped.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
MODE="${1:---dry-run}"
pending=$(inv_nodes pending staged | tr '\n' ' ')
[ -z "$pending" ] || die "nodes not yet active in deploy/inventory.tsv: $pending- finish onboarding (or remove them) before arming"
N_MEMBERS=${#V9_NODES[@]}
[ "$N_MEMBERS" -ge 3 ] || die "need at least 3 active nodes for a council (have $N_MEMBERS)"
THRESHOLD="${THRESHOLD:-$(majority "$N_MEMBERS")}"
[ $(( 2 * THRESHOLD )) -gt "$N_MEMBERS" ] && [ "$THRESHOLD" -ge 2 ] && [ "$THRESHOLD" -le "$N_MEMBERS" ] \
  || die "THRESHOLD=$THRESHOLD is not a strict majority of $N_MEMBERS"
_addrs=(); for _n in "${V9_NODES[@]}"; do
  [ -n "$(node_cap "$_n")" ] || die "$_n has no $(inv_cap_var "$_n") in $V8_ENV: it could never propose or approve"
  _addrs+=("${INV_ADDR[$_n]}")
done
MEMBERS="[$(IFS=,; echo "${_addrs[*]}")]"
MEMBER_NAMES="${V9_NODES[*]}"

require_cli; require_publisher
[ -n "${PKG_V9:-}" ] || die "no PKG_V9 recorded; run 02_upgrade.sh execute first"
check_v9_package "$PKG_V9"
[ -n "${V9_GRANT_VERIFIED:-}" ] || die "phase F not verified: run scripts/v9/03_switch_plugin.sh v9 first (the plugin must call v9 before arming)"

# Execute one call and print its digest; the CLI's response shape varies by
# release, so the effect is re-checked from chain state by the caller.
run_call() {   # <out.json> <function> <gas> args...
  local out="$1" fn="$2" gas="$3"; shift 3
  "$SUI" client call --package "$PKG_V9" --module quorum --function "$fn" --args "$@" --gas-budget "$gas" --json > "$out"
  python3 - "$out" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
st=json.dumps((d.get("effects") or {}).get("status", ""))
if "failure" in st.lower(): sys.exit("FATAL: tx failed: "+st)
def find(x,k):
    if isinstance(x,dict):
        if k in x and isinstance(x[k],str): return x[k]
        for v in x.values():
            r=find(v,k)
            if r: return r
    if isinstance(x,list):
        for v in x:
            r=find(v,k)
            if r: return r
print(find(d,"digest") or "?")
PY
}

simulate() {   # <function> args...   (as the publisher; free)
  local fn="$1"; shift
  local r; r=$(inspect_outcome "$PUBLISHER" "$PKG_V9" quorum "$fn" "$@")
  echo "  simulate $fn: $r"
  [ "$r" = success ] || die "$fn would fail ($r); nothing was done"
}

# ------------------------------------------------------------ step 1: Council
say "step 1: create_council (members $MEMBER_NAMES, threshold $THRESHOLD of $N_MEMBERS)"
governed=$(inspect_value "$PKG_V9" trust is_governed "$TRUST_REG")
echo "  trust::is_governed = ${governed:-?}"
case "$governed" in
  true)
    [ -n "${COUNCIL:-}" ] || die "TrustRegistry is governed but no COUNCIL is recorded: find it (CouncilCreated event) before going on"
    echo "  already armed: COUNCIL=$COUNCIL";;
  false)
    for c in "$ID_ADMIN_CAP" "$TRUST_ADMIN_CAP"; do
      o=$(object_owner "$c"); [ "$o" = "AddressOwner:$PUBLISHER" ] || die "$c is owned by $o, not the publisher"
    done
    simulate create_council "$ID_ADMIN_CAP" "$ID_REG" "$TRUST_ADMIN_CAP" "$TRUST_REG" "$MEMBERS" "$THRESHOLD"
    if [ "$MODE" = --execute ]; then
      echo
      echo "ONE-WAY: after this, peer revocation, grants, node registration, policy"
      echo "writes and minting need $THRESHOLD of: $MEMBER_NAMES. The identity AdminCap is consumed."
      confirm "arm governance on $TRUST_REG"
      tx=$(run_call "$V9_DIR/council.json" create_council 50000000 \
             "$ID_ADMIN_CAP" "$ID_REG" "$TRUST_ADMIN_CAP" "$TRUST_REG" "$MEMBERS" "$THRESHOLD")
      council=$(python3 - "$V9_DIR/council.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
ids=[c["objectId"] for c in d.get("objectChanges",[]) if c.get("type")=="created" and c.get("objectType","").endswith("::quorum::Council")]
print(ids[0] if len(ids)==1 else "")
PY
)
      [ -n "$council" ] || die "create_council tx $tx: could not find the Council in $V9_DIR/council.json; record COUNCIL by hand from the explorer"
      record COUNCIL "$council"; record COUNCIL_TX "$tx"
      [ "$(inspect_value "$PKG_V9" trust is_governed "$TRUST_REG")" = true ] || die "tx $tx done but is_governed is not true"
      echo "  OK: COUNCIL=$council (tx $tx)"
    fi;;
  *) die "could not read trust::is_governed";;
esac

# ------------------------------------------------------------ step 2: caps
say "step 2: hand the policy, issuer and cluster caps to the Council"
for spec in "deposit_policy_cap:POL_ADMIN_CAP:holds_policy_cap" \
            "deposit_issuer_cap:ISSUER_CAP:holds_issuer_cap" \
            "deposit_cluster_cap:CLUSTER_ADMIN_CAP:holds_cluster_cap"; do
  IFS=: read -r fn var view <<< "$spec"
  cap="${!var}"
  o=$(object_owner "$cap")
  case "$o" in
    "AddressOwner:$PUBLISHER")
      if [ -z "${COUNCIL:-}" ]; then echo "  $fn: waits for the Council (dry run)"; continue; fi
      simulate "$fn" "$COUNCIL" "$cap"
      if [ "$MODE" = --execute ]; then
        tx=$(run_call "$V9_DIR/$fn.json" "$fn" 20000000 "$COUNCIL" "$cap")
        record "${var}_DEPOSIT_TX" "$tx"
        echo "  $fn: done (tx $tx)"
      fi;;
    "ObjectOwner:"*) echo "  $fn: already held by the Council ($o)";;
    *) die "$var $cap is owned by $o; stop and investigate";;
  esac
done

if [ -n "${COUNCIL:-}" ]; then
  say "Council holds"
  for v in holds_identity_cap holds_policy_cap holds_issuer_cap; do
    echo "  $v = $(inspect_value "$PKG_V9" quorum "$v" "$COUNCIL")"
  done
  echo "  holds_cluster_cap = $(inspect_value "$PKG_V9" quorum holds_cluster_cap "$COUNCIL" "$CLUSTER")"
fi

if [ "$MODE" != --execute ]; then
  echo; echo "DRY RUN complete (nothing signed). Re-run with --execute to arm governance."
else
  echo; echo "Next: scripts/v9/05_verify.sh"
fi
