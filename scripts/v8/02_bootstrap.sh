#!/usr/bin/env bash
# 02_bootstrap.sh - ROLLOUT_V8.md phase D: on-chain bootstrap of the v8 package.
#
# Run in WSL as the publisher (active address 0xb87fb2af...), AFTER
# scripts/v8/01_publish.sh --execute has written deploy/v8/deployment.env.
#
#   scripts/v8/02_bootstrap.sh              # PLAN (default): print every command, sign nothing
#   scripts/v8/02_bootstrap.sh --simulate   # each step with `sui client call --dry-run` (reads chain, signs nothing)
#   scripts/v8/02_bootstrap.sh --execute    # really run the steps (signs + spends gas)
#
# Every Move call below was derived from the v8 sources in move/sources/*.move;
# the file:line of each signature is printed next to its step in plan mode.
#
# Environment overrides:
#   DEPLOY_ENV     path to deployment.env      (default: <repo>/deploy/v8/deployment.env)
#   SUI_BIN        sui binary                  (default: sui)
#   GAS_BUDGET     per-transaction budget MIST (default: 20000000 = 0.02 SUI, refunded if unused)
#   INITIAL_SCORE  trust::add_node score       (default: 80; MAX_SCORE is 100, gate is 50)
#   TRUST_GATE     failover trust gate         (default: 50)
#   LEASE_MS       create_cluster initial lease (default: 1200000 = 2 x lease.anchor.period.ms; MAX_LEASE_MS 3600000)
#   POLICY_MIN_TRUST / POLICY_OPS              (default: 50 / 3 = READ|WRITE, as scripts/bootstrap_testbed.sh)
#   TOKEN_OPS      CapToken allowed_ops mask   (default: 3 = READ|WRITE, equal to the policy mask)
#   TOKEN_DAYS     CapToken lifetime in days   (default: 180)
#   TOKEN_MAX_USES CapToken use bound          (default: 1000000, as the live v7 token)
#
# Idempotency: every step has an output variable (an object id, or a <STEP>_TX
# digest for steps that create no object). A step whose output OR digest is
# already recorded in deployment.env is never re-run, in any mode.
#
# Outputs (execute mode), appended to deployment.env as `export NAME=value`:
#   BOOT_ID_RPI{1,2,3}_TX, BOOT_TRUST_RPI{1,2,3}_TX           (digests)
#   TRUST_ADMIN_CAP_RPI{1,2,3}                                 (+ _TX)
#   BOOT_POLICY_PROTECTED_CNT_TX, BOOT_POLICY_DAC_AE_TX        (digests)
#   TOKEN_SUI_PROTECTED_CNT, TOKEN_SUI_DAC_AE                  (+ _TX)
#   CLUSTER, CLUSTER_ISV, CLUSTER_ADMIN_CAP                    (+ _TX)
#   BOOT_TOKEN_EXPIRY_MS                                       (the expiry actually minted)
# Raw CLI output of every step is kept in deploy/v8/bootstrap/ for the evidence trail.
set -euo pipefail

MODE="${1:---plan}"
case "$MODE" in
  --plan|--simulate|--execute) ;;
  -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
  *) echo "usage: $0 [--plan|--simulate|--execute]" >&2; exit 2 ;;
esac

PUBLISHER="0xb87fb2af21e29dd292d5b557b92d95a544794a589620f4b437f2247f075d6a1e"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY_ENV="${DEPLOY_ENV:-$REPO/deploy/v8/deployment.env}"
SUI_BIN="${SUI_BIN:-sui}"
LOG_DIR="$(dirname "$DEPLOY_ENV")/bootstrap"

GAS_BUDGET="${GAS_BUDGET:-20000000}"
INITIAL_SCORE="${INITIAL_SCORE:-80}"
TRUST_GATE="${TRUST_GATE:-50}"
LEASE_MS="${LEASE_MS:-1200000}"
POLICY_MIN_TRUST="${POLICY_MIN_TRUST:-50}"
POLICY_OPS="${POLICY_OPS:-3}"
TOKEN_OPS="${TOKEN_OPS:-3}"
TOKEN_DAYS="${TOKEN_DAYS:-180}"
TOKEN_MAX_USES="${TOKEN_MAX_USES:-1000000}"

# On-chain constants, as read from move/sources (checked again below).
MAX_SCORE=100          # trust.move:41
MAX_LEASE_MS=3600000   # failover.move:59
CLOCK=0x6

# Node facts (scripts/env.sh). cse_id strings are the ones the live v7
# identity registry holds (read via GraphQL 2026-11-10): in-cse / mn-cse-1 / mn-cse-2.
RPI1=0xef9c6271d8c6cc9e1d9707a117f876e7a8679509f141879bc05ae7bcffe1d5f9   # 10.25.96.200
RPI2=0x4be6060abaff0b4b6b7229558887f5f054cbe7d9836ba56eff35d848e13dc1f5   # 10.25.96.201
RPI3=0x27dacda1bdcb3fb8dc2a4b0d77b420deea5bb43d1047592ddadb19f35764ea10   # 10.25.96.203 (DAS / GRANT node)
ROLE_IN_CSE=1   # identity.move:29
ROLE_MN_CSE=2   # identity.move:30

# Protected resources the DAS serves (bench/provision_das.sh, scripts/bootstrap_testbed.sh).
RES_PROTECTED_CNT="/in-cse/in-name/sui-protected-cnt"   # legacy NOTIFY-path container
RES_DAC_AE="/in-cse/Csui-dac-ae"                        # C2: the DAC-protected AE (non-hierarchical ri)
CLUSTER_ID_BYTES='[69,69,95,53]'                        # "EE_5" (v7 cluster's RUVfNQ==)

die() { echo "FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- inputs
[ -f "$DEPLOY_ENV" ] || die "$DEPLOY_ENV not found - run scripts/v8/01_publish.sh --execute first (or set DEPLOY_ENV)"
grep -q $'\r' "$DEPLOY_ENV" && die "$DEPLOY_ENV has CRLF line endings"
# shellcheck disable=SC1090
source "$DEPLOY_ENV"

is_id() { [[ "${1:-}" =~ ^0x[0-9a-fA-F]{1,64}$ ]]; }
for v in PKG_V8 ID_REG TRUST_REG POLICY_REG ID_ADMIN_CAP TRUST_ADMIN_CAP POL_ADMIN_CAP ISSUER_CAP; do
  is_id "${!v:-}" || die "deployment.env: $v missing or not a 0x id (got '${!v:-}')"
done

# ---------------------------------------------------------------- sanity on parameters
[[ "$INITIAL_SCORE" =~ ^[0-9]+$ ]] && [ "$INITIAL_SCORE" -le "$MAX_SCORE" ] || die "INITIAL_SCORE must be 0..$MAX_SCORE (add_node silently clamps above it)"
[ "$INITIAL_SCORE" -gt "$TRUST_GATE" ] || die "INITIAL_SCORE ($INITIAL_SCORE) must be above TRUST_GATE ($TRUST_GATE)"
[ "$INITIAL_SCORE" -ge "$POLICY_MIN_TRUST" ] || die "INITIAL_SCORE below POLICY_MIN_TRUST - every access would DENY"
[ "$LEASE_MS" -le "$MAX_LEASE_MS" ] || die "LEASE_MS $LEASE_MS > MAX_LEASE_MS $MAX_LEASE_MS (create_cluster aborts with code 7)"
[ $(( TOKEN_OPS & ~POLICY_OPS )) -eq 0 ] || echo "WARN: TOKEN_OPS ($TOKEN_OPS) grants bits the policy mask ($POLICY_OPS) never allows"

# Cross-check the constants against the sources if the tree is present.
SRC="$REPO/move/sources"
if [ -d "$SRC" ]; then
  grep -q "const MAX_SCORE: u64 = $MAX_SCORE;" "$SRC/trust.move"            || die "trust.move MAX_SCORE changed - re-derive"
  grep -q "const MAX_LEASE_MS: u64 = 3_600_000;" "$SRC/failover.move"        || die "failover.move MAX_LEASE_MS changed - re-derive"
  grep -q "const ROLE_IN_CSE: u8 = $ROLE_IN_CSE;" "$SRC/identity.move"       || die "identity.move ROLE_IN_CSE changed"
  grep -q "const ROLE_MN_CSE: u8 = $ROLE_MN_CSE;" "$SRC/identity.move"       || die "identity.move ROLE_MN_CSE changed"
fi

# NOT `date +%s%3N`: the WSL Ubuntu on the publisher machine ships uutils
# coreutils 0.8.0, whose date ignores the %3N width and prints 9 nanosecond
# digits (a 19-digit "ms" value, ~1e6 x too large). Whole seconds x 1000 is
# exact enough for registered_at_ms and a 180-day expiry.
NOW_MS=$(( $(date +%s) * 1000 ))
[[ "$NOW_MS" =~ ^1[0-9]{12}$ ]] || die "clock sanity check failed: now_ms=$NOW_MS is not a 13-digit epoch-ms value"
TOKEN_EXPIRY_MS=$(( NOW_MS + TOKEN_DAYS * 86400000 ))
if [ -n "${BOOT_TOKEN_EXPIRY_MS:-}" ]; then TOKEN_EXPIRY_MS="$BOOT_TOKEN_EXPIRY_MS"; fi  # keep one expiry across partial re-runs

# ---------------------------------------------------------------- step table
# Each step: ID | output var | gas estimate (MIST) | signature ref | creates-spec | sui client call args...
# creates-spec: space-separated VAR=module::Type[@owner|#shared], parsed from objectChanges.
STEP_IDS=(); declare -A S_OUT S_EST S_SIG S_DESC S_CREATES S_ARGS

add_step() {  # id out est sig desc creates -- args...
  local id=$1 out=$2 est=$3 sig=$4 desc=$5 creates=$6; shift 7
  STEP_IDS+=("$id"); S_OUT[$id]=$out; S_EST[$id]=$est; S_SIG[$id]=$sig; S_DESC[$id]=$desc; S_CREATES[$id]=$creates
  local q="" a; for a in "$@"; do q+="$(printf '%q' "$a") "; done
  S_ARGS[$id]="$q"
}

# Gas estimates: net MIST (computation + storage - rebate) at testnet reference
# prices, conservative. Use --simulate after the publish for exact numbers.
# --- identity: identity.move:91 register(&AdminCap, &mut Registry, address, String, u8, u64)
add_step id_rpi1 BOOT_ID_RPI1_TX 3500000 "identity.move:91" "identity::register RPI1 as IN-CSE (role 1)" "" -- \
  --package "$PKG_V8" --module identity --function register \
  --args "$ID_ADMIN_CAP" "$ID_REG" "$RPI1" '"in-cse"' "$ROLE_IN_CSE" "$NOW_MS"
add_step id_rpi2 BOOT_ID_RPI2_TX 3500000 "identity.move:91" "identity::register RPI2 as MN-CSE (role 2)" "" -- \
  --package "$PKG_V8" --module identity --function register \
  --args "$ID_ADMIN_CAP" "$ID_REG" "$RPI2" '"mn-cse-1"' "$ROLE_MN_CSE" "$NOW_MS"
add_step id_rpi3 BOOT_ID_RPI3_TX 3500000 "identity.move:91" "identity::register RPI3 as MN-CSE (role 2)" "" -- \
  --package "$PKG_V8" --module identity --function register \
  --args "$ID_ADMIN_CAP" "$ID_REG" "$RPI3" '"mn-cse-2"' "$ROLE_MN_CSE" "$NOW_MS"

# --- trust: trust.move:130 add_node(&AdminCap, &mut TrustRegistry, address, u64, &Clock)
# Validates the cap (A1). NOT rate-limited: A12's assert_write_allowed is only
# called from increase/decrease (trust.move:169,194), so 3 back-to-back adds are fine.
for n in 1 2 3; do
  addr_var="RPI$n"
  add_step "trust_rpi$n" "BOOT_TRUST_RPI${n}_TX" 3000000 "trust.move:130" "trust::add_node RPI$n score $INITIAL_SCORE" "" -- \
    --package "$PKG_V8" --module trust --function add_node \
    --args "$TRUST_ADMIN_CAP" "$TRUST_REG" "${!addr_var}" "$INITIAL_SCORE" "$CLOCK"
done

# --- trust: trust.move:346 grant_admin_registered(&AdminCap, &mut TrustRegistry, address, &mut TxContext)
# mint_and_register (trust.move:313) validates the granting cap, adds the new id
# to the TR7 validity set and public_transfer()s the cap to `recipient`.
for n in 1 2 3; do
  addr_var="RPI$n"
  add_step "cap_rpi$n" "TRUST_ADMIN_CAP_RPI$n" 4000000 "trust.move:346" "trust::grant_admin_registered -> own AdminCap for RPI$n" \
    "TRUST_ADMIN_CAP_RPI$n=trust::AdminCap@${!addr_var}" -- \
    --package "$PKG_V8" --module trust --function grant_admin_registered \
    --args "$TRUST_ADMIN_CAP" "$TRUST_REG" "${!addr_var}"
done

# --- policy: policy.move:99 set_policy(&PolicyAdminCap, &mut PolicyRegistry, String, u64, u8)
add_step pol_cnt BOOT_POLICY_PROTECTED_CNT_TX 4000000 "policy.move:99" "policy::set_policy $RES_PROTECTED_CNT min_trust=$POLICY_MIN_TRUST mask=$POLICY_OPS" "" -- \
  --package "$PKG_V8" --module policy --function set_policy \
  --args "$POL_ADMIN_CAP" "$POLICY_REG" "\"$RES_PROTECTED_CNT\"" "$POLICY_MIN_TRUST" "$POLICY_OPS"
add_step pol_dac BOOT_POLICY_DAC_AE_TX 4000000 "policy.move:99" "policy::set_policy $RES_DAC_AE min_trust=$POLICY_MIN_TRUST mask=$POLICY_OPS (C2)" "" -- \
  --package "$PKG_V8" --module policy --function set_policy \
  --args "$POL_ADMIN_CAP" "$POLICY_REG" "\"$RES_DAC_AE\"" "$POLICY_MIN_TRUST" "$POLICY_OPS"

# --- cap_token: cap_token.move:128 mint(&IssuerCap, address owner, String, u8, u64 expiry_ms, u64 max_uses, &mut TxContext)
# owner MUST be RPI3: validate_for_use asserts sender == requester == token.owner (cap_token.move:188-189).
add_step tok_cnt TOKEN_SUI_PROTECTED_CNT 4500000 "cap_token.move:128" "cap_token::mint owner=RPI3 $RES_PROTECTED_CNT ops=$TOKEN_OPS" \
  "TOKEN_SUI_PROTECTED_CNT=cap_token::CapToken@$RPI3" -- \
  --package "$PKG_V8" --module cap_token --function mint \
  --args "$ISSUER_CAP" "$RPI3" "\"$RES_PROTECTED_CNT\"" "$TOKEN_OPS" "$TOKEN_EXPIRY_MS" "$TOKEN_MAX_USES"
add_step tok_dac TOKEN_SUI_DAC_AE 4500000 "cap_token.move:128" "cap_token::mint owner=RPI3 $RES_DAC_AE ops=$TOKEN_OPS (C2)" \
  "TOKEN_SUI_DAC_AE=cap_token::CapToken@$RPI3" -- \
  --package "$PKG_V8" --module cap_token --function mint \
  --args "$ISSUER_CAP" "$RPI3" "\"$RES_DAC_AE\"" "$TOKEN_OPS" "$TOKEN_EXPIRY_MS" "$TOKEN_MAX_USES"

# --- failover: failover.move:120 create_cluster(vector<u8>, address, u64, u64, &Clock, &mut TxContext)
# Permissionless; shares the Cluster and transfers a ClusterAdminCap to the sender.
# Deliberately LAST: the lease starts ticking at creation (now + LEASE_MS), so the
# closer this runs to the phase-F cutover, the longer RPI1 holds an unexpired lease.
add_step cluster CLUSTER 5000000 "failover.move:120" "failover::create_cluster \"EE_5\" parent=RPI1 gate=$TRUST_GATE lease=${LEASE_MS}ms" \
  "CLUSTER=failover::Cluster#shared CLUSTER_ADMIN_CAP=failover::ClusterAdminCap@$PUBLISHER" -- \
  --package "$PKG_V8" --module failover --function create_cluster \
  --args "$CLUSTER_ID_BYTES" "$RPI1" "$TRUST_GATE" "$LEASE_MS" "$CLOCK"

# ---------------------------------------------------------------- helpers
recorded() {  # step id -> 0 if its output or its digest is already in deployment.env
  local out=${S_OUT[$1]}
  grep -qE "^export (${out}|${out%_TX}_TX)=" "$DEPLOY_ENV"
}

append_env() {  # NAME VALUE
  grep -qE "^export $1=" "$DEPLOY_ENV" && die "refusing to overwrite $1 in $DEPLOY_ENV"
  printf 'export %s=%s\n' "$1" "$2" >> "$DEPLOY_ENV"
  echo "      + export $1=$2"
}

pretty_cmd() {  # print a sui client call readably, quoting only what needs it
  local out="sui client call" a
  for a in "$@"; do
    if [[ "$a" =~ ^[A-Za-z0-9_./:@=+-]+$ ]]; then out+=" $a"; else out+=" '${a//\'/\'\\\'\'}'"; fi
  done
  echo "$out --gas-budget $GAS_BUDGET --json"
}

# Parse `sui client call --json` effects; print NAME=value lines (incl. NAME_ISV for shared).
parse_effects() {  # json_path creates-spec
  python3 - "$1" "$PKG_V8" "$2" <<'PY'
import json, sys
path, pkg, spec = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
st = d.get("effects", {}).get("status", {})
if st.get("status") != "success":
    sys.exit(f"transaction not successful: {st}")
def norm(a):
    a = a.lower()
    a = a[2:] if a.startswith("0x") else a
    return "0x" + a.rjust(64, "0")
pkg = norm(pkg)
print(f"DIGEST={d.get('digest') or d['effects'].get('transactionDigest')}")
created = [c for c in d.get("objectChanges", []) if c.get("type") == "created"]
for item in spec.split():
    name, want = item.split("=", 1)
    shared = want.endswith("#shared")
    owner = None
    if shared: want = want[:-len("#shared")]
    elif "@" in want: want, owner = want.split("@", 1)
    mod, typ = want.split("::")
    hits = []
    for c in created:
        t = c["objectType"].split("<")[0].split("::")
        if len(t) != 3 or norm(t[0]) != pkg or t[1] != mod or t[2] != typ: continue
        o = c.get("owner")
        if shared:
            if not (isinstance(o, dict) and "Shared" in o): continue
        elif owner is not None:
            if not (isinstance(o, dict) and norm(o.get("AddressOwner", "0x0")) == norm(owner)): continue
        hits.append(c)
    if len(hits) != 1:
        sys.exit(f"expected exactly 1 created {pkg}::{mod}::{typ} (owner {owner or ('shared' if shared else 'any')}), found {len(hits)}")
    c = hits[0]
    print(f"{name}={c['objectId']}")
    if shared:
        print(f"{name}_ISV={c['owner']['Shared']['initial_shared_version']}")
PY
}

# ---------------------------------------------------------------- preflight (not in plan mode)
if [ "$MODE" != "--plan" ]; then
  command -v "$SUI_BIN" >/dev/null || die "sui CLI '$SUI_BIN' not found"
  command -v python3 >/dev/null || die "python3 not found"
  active=$("$SUI_BIN" client active-address)
  [ "$active" = "$PUBLISHER" ] || die "active address is $active, expected publisher $PUBLISHER"
  [ "$("$SUI_BIN" client active-env)" = "testnet" ] || die "active env is not testnet"
  bal=$("$SUI_BIN" client gas --json | python3 -c 'import json,sys; print(sum(int(c.get("mistBalance",0)) for c in json.load(sys.stdin)))')
  echo "== publisher gas balance: $bal MIST ($(python3 -c "print(f'{$bal/1e9:.4f}')") SUI)"
  [ "$bal" -gt "$GAS_BUDGET" ] || die "balance below one gas budget"
  mkdir -p "$LOG_DIR"
fi

# ---------------------------------------------------------------- run / print
echo "== v8 bootstrap  mode=$MODE  env=$DEPLOY_ENV"
echo "   PKG_V8=$PKG_V8"
echo "   now_ms=$NOW_MS  token_expiry_ms=$TOKEN_EXPIRY_MS ($(date -u -d "@$((TOKEN_EXPIRY_MS/1000))" +%Y-%m-%dT%H:%MZ 2>/dev/null || echo "+${TOKEN_DAYS}d"))"
echo "   gas budget per tx=$GAS_BUDGET MIST; estimates are net cost (computation+storage-rebate)"
echo

# UNTIL_STEP=N runs only steps 1..N. Used to hold back create_cluster (the last
# step): its lease starts counting at creation, so it should land at cutover,
# not before config generation and deployment have even begun.
UNTIL_STEP="${UNTIL_STEP:-999}"

total=0; i=0; ran=0
for id in "${STEP_IDS[@]}"; do
  i=$((i+1))
  if [ "$i" -gt "$UNTIL_STEP" ]; then
    printf '[%02d] %s\n     HELD BACK (UNTIL_STEP=%s)\n\n' "$i" "${S_DESC[$id]}" "$UNTIL_STEP"
    continue
  fi
  eval "args=(${S_ARGS[$id]})"
  printf '[%02d] %s\n' "$i" "${S_DESC[$id]}"
  printf '     signature: move/sources/%s   output: %s\n' "${S_SIG[$id]}" "${S_OUT[$id]}"
  if recorded "$id"; then
    echo "     SKIP: ${S_OUT[$id]} already recorded in deployment.env"
    echo; continue
  fi
  total=$(( total + S_EST[$id] ))
  echo "     \$ $(pretty_cmd "${args[@]}")"
  printf '     est. %d MIST (%s SUI)   running total %d MIST (%s SUI)\n' \
    "${S_EST[$id]}" "$(awk "BEGIN{printf \"%.4f\", ${S_EST[$id]}/1e9}")" \
    "$total" "$(awk "BEGIN{printf \"%.4f\", $total/1e9}")"

  case "$MODE" in
    --plan) ;;
    --simulate)
      out="$LOG_DIR/$(printf '%02d' "$i")_${id}.dryrun.json"
      if "$SUI_BIN" client call "${args[@]}" --gas-budget "$GAS_BUDGET" --dry-run --json >"$out" 2>"$out.err"; then
        python3 - "$out" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); e=d.get("effects",{}); g=e.get("gasUsed",{})
c=int(g.get("computationCost",0))+int(g.get("storageCost",0))-int(g.get("storageRebate",0))
print(f"     simulated: {e.get('status',{}).get('status')} {e.get('status',{}).get('error','')}  net gas {c} MIST")
PY
      else
        echo "     simulate FAILED (see $out.err). No step consumes an earlier step's output, so this is a real problem."
      fi ;;
    --execute)
      out="$LOG_DIR/$(printf '%02d' "$i")_${id}.json"
      echo "     executing..."
      if ! "$SUI_BIN" client call "${args[@]}" --gas-budget "$GAS_BUDGET" --json >"$out" 2>"$out.err"; then
        cat "$out.err" >&2
        die "step $i ($id) failed - nothing recorded for it; steps 1..$((i-1)) are recorded. Fix and re-run (completed steps are skipped)."
      fi
      # 1) status + digest first, and record the digest at once: from here on
      #    the step counts as done, so a re-run can never repeat a landed tx.
      status_line=$(parse_effects "$out" "") || { cat "$out.err" >&2; die "step $i ($id): transaction not successful - see $out"; }
      digest=$(sed -n 's/^DIGEST=//p' <<<"$status_line")
      [ "$ran" -eq 0 ] && printf '\n# --- appended by scripts/v8/02_bootstrap.sh %s ---\n' "$(date -u +%FT%TZ)" >> "$DEPLOY_ENV"
      out_var=${S_OUT[$id]}
      append_env "${out_var%_TX}_TX" "$digest"
      if [ -z "${BOOT_TOKEN_EXPIRY_MS:-}" ] && [[ "$id" == tok_* ]]; then
        append_env BOOT_TOKEN_EXPIRY_MS "$TOKEN_EXPIRY_MS"; BOOT_TOKEN_EXPIRY_MS=$TOKEN_EXPIRY_MS
      fi
      ran=$((ran+1))
      # 2) created objects (caps, tokens, cluster + ISV)
      if [ -n "${S_CREATES[$id]}" ]; then
        parsed=$(parse_effects "$out" "${S_CREATES[$id]}") || die "step $i ($id) LANDED (digest $digest, recorded) but its created objects did not parse - read them from $out and record them before running 03"
        while IFS='=' read -r k v; do
          [ "$k" = DIGEST ] && continue
          append_env "$k" "$v"
        done <<<"$parsed"
      fi ;;
  esac
  echo
done

echo "== estimated total for pending steps: $total MIST ($(awk "BEGIN{printf \"%.4f\", $total/1e9}") SUI); publisher had ~1.19 SUI after publish"
case "$MODE" in
  --plan)     echo "PLAN only - nothing was signed. Review, then: $0 --simulate  (exact gas)  and  $0 --execute" ;;
  --simulate) echo "SIMULATE complete - nothing was signed. Raw dry-runs in $LOG_DIR" ;;
  --execute)  echo "OK: $ran step(s) executed and recorded in $DEPLOY_ENV. Next: scripts/v8/03_gen_config.sh" ;;
esac
