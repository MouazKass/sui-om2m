#!/usr/bin/env bash
# onboard_onchain.sh - the three on-chain steps that admit a new node. Run in
# WSL as the publisher (scripts/onboard_node.sh calls it for you).
#
#   scripts/onboard_onchain.sh register <name> [--execute]   identity::register (role + cse_id from the inventory)
#   scripts/onboard_onchain.sh trust    <name> [--execute]   trust::add_node    (initial score 80, like genesis)
#   scripts/onboard_onchain.sh cap      <name> [--execute]   trust::grant_admin_registered -> the node's OWN AdminCap
#   scripts/onboard_onchain.sh status   <name>               read-only: what is already on-chain
#
# Without --execute a step only PRINTS the exact transaction (and, with
# --simulate, dry-runs it for free); nothing is signed. Every step first reads
# chain state and is skipped if its effect is already there, so re-running is
# safe. 'cap' records TRUST_ADMIN_CAP_<NAME> in deploy/v8/deployment.env and
# marks the node active in deploy/inventory.tsv once all three are on-chain.
#
# Signed by the publisher (the holder of the identity and genesis trust
# AdminCaps). Once v9 governance is armed (deploy/v9/deployment.env has
# COUNCIL), the publisher can no longer do this: each step becomes a k-of-n
# council proposal by member nodes (quorum ACT_ID_REGISTER 20,
# ACT_TRUST_ADD_NODE 12, ACT_TRUST_GRANT_ADMIN 10, then ACT_ADD_MEMBER 1), and
# this script stops and says so.
set -euo pipefail
. "$(dirname "$0")/v9/lib.sh"     # SUI, PUBLISHER, inspect_value, inspect_outcome, inventory

STEP="${1:-}"; NAME="${2:-}"; FLAG="${3:-}"
[ -n "$STEP" ] && [ -n "$NAME" ] || { sed -n '2,22p' "$0"; exit 1; }
inv_require "$NAME"
ADDR=${INV_ADDR[$NAME]}
[ -n "$ADDR" ] || die "$NAME has no sui_address yet: run 'scripts/onboard_node.sh $NAME sui-key' first"
CAPV=$(inv_cap_var "$NAME")
INITIAL_SCORE="${INITIAL_SCORE:-80}"      # = scripts/v8/02_bootstrap.sh genesis value
GAS=20000000
CALL_PKG=${PKG_V9:-$PKG_V8}               # either works before governance; follow the plugin target
case "${INV_ROLE[$NAME]}" in in-cse) ROLE=1;; mn-cse) ROLE=2;; esac   # identity.move ROLE_IN_CSE / ROLE_MN_CSE
grep -q "const ROLE_MN_CSE: u8 = 2;" "$REPO/move/sources/identity.move" || die "identity.move role constants changed"

if [ -n "${COUNCIL:-}" ]; then
  die "governance is armed (COUNCIL=$COUNCIL): the publisher cannot admit nodes any more.
  (the genesis trust AdminCap was also revoked by council proposal 5, 2026-11-10).
  Admit $NAME by council proposals from member nodes, from Git Bash; each one is
  'propose' on one member, 'approve' on k-1 others, then 'execute':
    scripts/v9/council.sh propose rpi1 id-register       $ADDR ${INV_CSEID[$NAME]} $ROLE
    scripts/v9/council.sh propose rpi1 trust-add-node    $ADDR '' $INITIAL_SCORE
    scripts/v9/council.sh propose rpi1 trust-grant-admin $ADDR
    scripts/v9/council.sh propose rpi1 add-member        $ADDR   (raise the threshold first if 2k would no longer exceed n)
    scripts/v9/council.sh approve <member> <proposal-id>; scripts/v9/council.sh execute <member> <proposal-id>
  See V9_DESIGN.md and move/tests/quorum_tests.move (onboard_node_identity_then_trust)."
fi

registered() { [ "$(inspect_value "$CALL_PKG" identity is_registered "$ID_REG" "$ADDR")" = true ]; }
has_trust()  { [ "$(inspect_value "$CALL_PKG" trust has_node "$TRUST_REG" "$ADDR")" = true ]; }
cap_recorded() { [ -n "${!CAPV:-}" ]; }

# run_or_print <description> <module> <function> args...
run_or_print() {
  local desc="$1" mod="$2" fn="$3"; shift 3
  local cmd=("$SUI" client call --package "$CALL_PKG" --module "$mod" --function "$fn" --args "$@" --gas-budget "$GAS")
  echo "  tx: $desc"
  printf '    %q' "${cmd[@]}"; echo
  case "$FLAG" in
    --execute)
      require_publisher
      "${cmd[@]}" --json > "$V9_DIR/onboard-$NAME-$fn.json" || die "$fn failed (see $V9_DIR/onboard-$NAME-$fn.json)"
      python3 - "$V9_DIR/onboard-$NAME-$fn.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
st=(d.get("effects") or {}).get("status") or {}
if json.dumps(st).lower().find("success") < 0: sys.exit("FATAL: tx status %s" % json.dumps(st))
print("  executed: digest", d.get("digest") or (d.get("effects") or {}).get("transactionDigest"))
PY
      ;;
    --simulate)
      require_publisher
      "${cmd[@]}" --dry-run 2>&1 | grep -iE "status|error|abort" | head -3 | sed 's/^/    dry-run: /'
      ;;
    *) echo "  (not executed: re-run with --execute, or --simulate for a free dry run)";;
  esac
}

show_status() {
  echo "$NAME ${INV_IP[$NAME]} $ADDR (inventory status ${INV_STATUS[$NAME]})"
  echo "  identity::is_registered = $(inspect_value "$CALL_PKG" identity is_registered "$ID_REG" "$ADDR")"
  echo "  trust::has_node         = $(inspect_value "$CALL_PKG" trust has_node "$TRUST_REG" "$ADDR")"
  if cap_recorded; then
    echo "  $CAPV = ${!CAPV} (valid: $(inspect_value "$CALL_PKG" trust is_cap_valid "$TRUST_REG" "${!CAPV}"), owner: $(object_owner "${!CAPV}"))"
  else
    echo "  $CAPV not recorded"
  fi
}

require_cli
case "$STEP" in
  status) show_status ;;

  register)
    if registered; then echo "  $NAME already registered - skipped"; exit 0; fi
    NOW_MS=$(( $(date +%s) * 1000 ))
    run_or_print "identity::register $NAME as ${INV_ROLE[$NAME]} (role $ROLE, cse_id ${INV_CSEID[$NAME]})" \
      identity register "$ID_ADMIN_CAP" "$ID_REG" "$ADDR" "\"${INV_CSEID[$NAME]}\"" "$ROLE" "$NOW_MS"
    [ "$FLAG" != --execute ] || registered || die "register executed but is_registered is not true yet (indexer lag? re-run status)"
    ;;

  trust)
    registered || die "$NAME is not registered yet (B10: an unregistered address is never a trust member) - run 'register' first"
    if has_trust; then echo "  $NAME already in the trust registry - skipped"; exit 0; fi
    run_or_print "trust::add_node $NAME score $INITIAL_SCORE" \
      trust add_node "$TRUST_ADMIN_CAP" "$TRUST_REG" "$ADDR" "$INITIAL_SCORE" 0x6
    ;;

  cap)
    registered && has_trust || die "$NAME needs 'register' and 'trust' first"
    if cap_recorded; then
      echo "  $CAPV already recorded (${!CAPV}) - skipped"
    else
      run_or_print "trust::grant_admin_registered -> own AdminCap for $NAME" \
        trust grant_admin_registered "$TRUST_ADMIN_CAP" "$TRUST_REG" "$ADDR"
      [ "$FLAG" = --execute ] || exit 0
      cap=$(python3 - "$V9_DIR/onboard-$NAME-grant_admin_registered.json" "$ADDR" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); want=sys.argv[2].lower()
ids=[c["objectId"] for c in d.get("objectChanges",[])
     if c.get("type")=="created" and c.get("objectType","").endswith("::trust::AdminCap")
     and str((c.get("owner") or {}).get("AddressOwner","")).lower()==want]
print(ids[0] if len(ids)==1 else "")
PY
)
      [ -n "$cap" ] || die "could not find the new AdminCap owned by $ADDR in the tx output; record $CAPV by hand"
      tx=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("digest",""))' "$V9_DIR/onboard-$NAME-grant_admin_registered.json")
      {
        echo "# --- appended by scripts/onboard_onchain.sh $(date -u +%FT%TZ) ---"
        echo "export ${CAPV}_TX=$tx"
        echo "export $CAPV=$cap"
      } >> "$V8_ENV"
      export "$CAPV=$cap"
      echo "  recorded $CAPV=$cap in $V8_ENV"
    fi
    if [ "${INV_STATUS[$NAME]}" != active ]; then
      inv_set "$NAME" status active
      echo "  $NAME is now status=active in $INVENTORY"
    fi
    ;;

  *) die "unknown step '$STEP' (register | trust | cap | status)";;
esac
