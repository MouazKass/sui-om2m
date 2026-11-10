#!/usr/bin/env bash
# 03_gen_config.sh - ROLLOUT_V8.md phase E: generate every node's config from
# deploy/v8/deployment.env. The outputs are GENERATED and must never be
# hand-edited; change deployment.env (or this script) and regenerate.
#
#   scripts/v8/03_gen_config.sh
#
# Pure file generation: no sui CLI, no network, no ssh. Pushing the files to
# the Pis (durable store ~/sui-runtime-config/ first, then /tmp) is phase E's
# next step and is NOT done here.
#
# Environment overrides:
#   DEPLOY_ENV    deployment.env incl. the ids 02_bootstrap.sh appended
#                 (default: <repo>/deploy/v8/deployment.env)
#   OUT_DIR       output root (default: <repo>/deploy/v8). Writes
#                 $OUT_DIR/nodes/<name>/{sui.properties,sui.mappings.properties} for every
#                 status=active node in deploy/inventory.tsv
#                 and $OUT_DIR/env.v8.sh
#   INVENTORY     node list (default: <repo>/deploy/inventory.tsv). Each active node's own
#                 trust AdminCap is TRUST_ADMIN_CAP_<NAME> in deployment.env.
#   ENV_SH        existing env.sh to diff the fragment against (default: <repo>/scripts/env.sh; never written)
#   V7_DIR        optional dir holding the LIVE v7 files as $V7_DIR/rpiN/sui.properties.
#                 If present: sui.cli.path is carried over from it, and a key-level
#                 v7 -> v8 diff is printed per node.
#   SUI_CLI_PATH  sui.cli.path when V7_DIR does not supply it (default: /usr/local/bin/sui,
#                 the value in config/sui.properties.sample - CONFIRM against the live file)
#
# Ends with a self-check that re-parses every generated file with
# java.util.Properties semantics (python3; plus real Java if `java` >= 11 is on
# PATH) and fails if any token key lost its "::" - the C6 bug can never ship.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY_ENV="${DEPLOY_ENV:-$REPO/deploy/v8/deployment.env}"
OUT_DIR="${OUT_DIR:-$REPO/deploy/v8}"
ENV_SH="${ENV_SH:-$REPO/scripts/env.sh}"
V7_DIR="${V7_DIR:-}"
PUBLISHER="0xb87fb2af21e29dd292d5b557b92d95a544794a589620f4b437f2247f075d6a1e"
GRAPHQL_URL="https://graphql.testnet.sui.io/graphql"

die() { echo "FATAL: $*" >&2; exit 1; }
# shellcheck source=../lib/inventory.sh
. "$REPO/scripts/lib/inventory.sh"
inv_load
command -v python3 >/dev/null || die "python3 is required for the self-check"

[ -f "$DEPLOY_ENV" ] || die "$DEPLOY_ENV not found (set DEPLOY_ENV)"
grep -q $'\r' "$DEPLOY_ENV" && die "$DEPLOY_ENV has CRLF line endings"
# shellcheck disable=SC1090
source "$DEPLOY_ENV"

# v9 switch (scripts/v9/03_switch_plugin.sh writes this file; delete it to go
# back to v8). CALL_PKG is the package the plugin CALLS (sui.package.id); type
# names always keep the original id PKG_V8 (sui.package.original.id).
PLUGIN_TARGET="${PLUGIN_TARGET:-$REPO/deploy/v9/plugin-target.env}"
CALL_PKG=$PKG_V8
DENY_FLUSH=false
if [ -f "$PLUGIN_TARGET" ]; then
  grep -q $'\r' "$PLUGIN_TARGET" && die "$PLUGIN_TARGET has CRLF line endings"
  # shellcheck disable=SC1090
  source "$PLUGIN_TARGET"
  [[ "$CALL_PKG" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "$PLUGIN_TARGET: CALL_PKG=$CALL_PKG is not a package id"
  case "$DENY_FLUSH" in true|false) ;; *) die "$PLUGIN_TARGET: DENY_FLUSH must be true or false";; esac
  echo "plugin target override: sui.package.id=$CALL_PKG, deny flush=$DENY_FLUSH (from $PLUGIN_TARGET)"
fi

is_id() { [[ "${1:-}" =~ ^0x[0-9a-fA-F]{1,64}$ ]]; }
REQUIRED=(PKG_V8 ID_REG TRUST_REG POLICY_REG AUDIT_TRAIL ISSUER_CAP ID_ADMIN_CAP TRUST_ADMIN_CAP
          POL_ADMIN_CAP AUDIT_ADMIN_CAP UPGRADE_CAP
          CLUSTER CLUSTER_ADMIN_CAP TOKEN_SUI_PROTECTED_CNT TOKEN_SUI_DAC_AE)
missing=()
for v in "${REQUIRED[@]}"; do is_id "${!v:-}" || missing+=("$v"); done
[ ${#missing[@]} -eq 0 ] || die "deployment.env lacks: ${missing[*]} - run 01_publish.sh and 02_bootstrap.sh --execute first"

# ---------------------------------------------------------------- node facts (deploy/inventory.tsv)
# Every status=active node gets a config. Each must have its OWN trust AdminCap,
# recorded as TRUST_ADMIN_CAP_<NAME> in deployment.env (02_bootstrap.sh for the
# genesis nodes, scripts/onboard_node.sh for later ones).
mapfile -t NODES < <(inv_nodes active)
[ ${#NODES[@]} -ge 2 ] || die "need at least 2 active nodes in $INVENTORY (have ${#NODES[@]})"
declare -A ADDR=() IP=() CAP=()
for n in "${NODES[@]}"; do
  ADDR[$n]=${INV_ADDR[$n]}; IP[$n]=${INV_IP[$n]}
  v=$(inv_cap_var "$n"); CAP[$n]=${!v:-}
  is_id "${CAP[$n]}" || die "active node $n has no $v in deployment.env - finish onboarding (scripts/onboard_node.sh $n onchain-cap)"
done
# Per-node caps must be distinct (TR7: each node's cap individually revocable).
[ "$(printf '%s\n' "${CAP[@]}" | sort | uniq -d)" = "" ] || die "per-node trust AdminCaps are not distinct"
DAS_NODE=$(inv_das)   # holds the CapTokens; both originators map to its address

# Originators and protected resources (bench/provision_das.sh, scripts/bootstrap_testbed.sh).
ORIGINATORS=("admin:admin" "Csensor-001")
RES_PROTECTED_CNT="/in-cse/in-name/sui-protected-cnt"
RES_DAC_AE="/in-cse/Csui-dac-ae"
declare -A TOKEN_FOR=( ["$RES_PROTECTED_CNT"]=$TOKEN_SUI_PROTECTED_CNT ["$RES_DAC_AE"]=$TOKEN_SUI_DAC_AE )
RESOURCES=("$RES_PROTECTED_CNT" "$RES_DAC_AE")

STAMP="GENERATED by scripts/v8/03_gen_config.sh from $(basename "$DEPLOY_ENV") (PKG_V8=$PKG_V8, publish digest ${DIGEST:-?}) at $(date -u +%FT%TZ). DO NOT HAND-EDIT - regenerate."

# java.util.Properties key escaping: '\' first, then the separators ':' '=' and
# whitespace. Keys here always start with addr./token. so leading '#'/'!' never arise.
esc_key() {
  local k=$1
  k=${k//\\/\\\\}; k=${k//:/\\:}; k=${k//=/\\=}; k=${k// /\\ }; k=${k//$'\t'/\\t}
  printf '%s' "$k"
}

v7_value() {  # node key -> value from the live v7 file, if supplied
  local f="$V7_DIR/$1/sui.properties"
  [ -n "$V7_DIR" ] && [ -f "$f" ] || return 0
  sed -n "s/^[[:space:]]*$2[[:space:]]*[=:][[:space:]]*//p" "$f" | tail -1 | tr -d '\r'
}

# ---------------------------------------------------------------- generators
gen_sui_properties() {  # node
  local n=$1 cli
  cli=$(v7_value "$n" sui.cli.path); cli=${cli:-${SUI_CLI_PATH:-/usr/local/bin/sui}}
  cat <<EOF
# sui.properties for $n (${IP[$n]})
# $STAMP
#
# --- keys present in the live v7 file (same structure, v8 values) ---
sui.cli.path=$cli
sui.env=testnet
sui.package.id=$CALL_PKG
# Type-origin package id: Move type names (e.g. ParentPoaKey) keep the id of the
# package that defined them across compatible upgrades. Stays $PKG_V8 even when
# sui.package.id moves to an upgraded package (v9). Plugin default: sui.package.id.
sui.package.original.id=$PKG_V8
sui.identity.registry.id=$ID_REG
sui.trust.registry.id=$TRUST_REG
sui.policy.registry.id=$POLICY_REG
sui.audit.trail.id=$AUDIT_TRAIL
sui.failover.cluster.id=$CLUSTER
sui.clock.id=0x6
sui.node.address=${ADDR[$n]}
sui.gas.budget=20000000
mqtt.broker.url=tcp://${IP[$n]}:1883
failover.heartbeat.period.ms=5000
failover.heartbeat.timeout.ms=15000
failover.lease.anchor.period.ms=600000
failover.parent.selfcheck.period.ms=15000
# This node's OWN trust AdminCap (trust::grant_admin_registered -> ${ADDR[$n]}).
trust.admin.cap.id=${CAP[$n]}
sui.use.native.rpc=true
sui.das.cache.ttl.ms=5000

# --- F3 (2026-11-10): DENYs cost no gas ---
# Every decision is simulated (free) first; only a simulated GRANT is signed
# and submitted. A DENY is never a paid transaction any more.
sui.das.precheck.enabled=true
# Repeat of a recent DENY (same originator/resource/op) is answered locally.
sui.das.deny.cache.ttl.ms=10000
sui.das.deny.cache.max=1024
# An originator with this many DENY verdicts in one window is throttled for the rest of it.
sui.das.deny.rate.max=30
sui.das.deny.rate.window.ms=60000
# Structured JSON-lines record of every DENY (bind-mounted, survives restarts).
sui.das.deny.log.path=/var/lib/sui-om2m/deny-log.jsonl
sui.das.deny.log.max.bytes=5242880
sui.das.deny.log.keep=3
# v9 only: anchor DENY windows on-chain (evaluator::log_deny_batch). The
# function does not exist in v8, so this stays false until the v9 upgrade.
sui.das.deny.audit.flush.enabled=$DENY_FLUSH
sui.das.deny.audit.flush.interval.min=15

# --- added for v8 ---
# Public fullnodes no longer serve JSON-RPC; every read/simulate/execute goes here.
sui.graphql.url=$GRAPHQL_URL

# --- SuiConfig keys not in the v7 file, pinned to their code defaults ---
# min_required fed into trust::require_min (PTB step 2); = policy min_trust = cluster gate.
sui.min.trust=50
sui.das.apoc.path=sui-das

# --- TrustConfig (B9/B10/B11/B12), pinned to their code defaults so the
# --- evaluated configuration is on record. 8 weights must sum to 100.
trust.weight.heartbeat=25
trust.weight.malformed=10
trust.weight.rate=10
trust.weight.clock=5
trust.weight.denied_burst=25
trust.weight.historical=10
trust.weight.inactive=5
trust.weight.garbage=10
trust.ema.alpha=0.30
trust.tick.period.ms=1000
trust.window.ms=60000
trust.peer.liveness.ms=30000
trust.rate.ceiling=300
trust.clock.max.drift.ms=5000
trust.denied.burst.threshold=20
trust.baseline.warmup.ms=300000
trust.inactivity.gap.ms=1800000
# Must mirror evolution.move tier_for(): 25 / 50 / 75 / 90.
trust.tier.boundaries=0,25,50,75,90
trust.tier.hysteresis=2.0
trust.tier.confirm.ticks=2
trust.ema.persist.period.ms=30000
trust.membership.cache.ttl.ms=60000

# --- read by the plugin but deliberately LEFT AT DEFAULT (the v7 file does not
# --- set them; they are container-path or behaviour switches - decide in phase F)
#sui.rpc.url=https://fullnode.testnet.sui.io:443        (legacy; unused for chain I/O since GraphQL)
#sui.keystore.path=\${user.home}/.sui/sui_config/sui.keystore   (container mounts /root/.sui/sui_config)
#sui.poa.file.path=/etc/sui-cluster/current-parent-poa
#sui.role.switch.enabled=false

# --- advertised Point-of-Access while this node holds the parent role.
# FailoverManager publishes it on taking up parent duties and re-checks it on
# every lease anchor (it used to be published only after a claim, so the
# initial parent and any restarted parent never advertised one).
sui.parent.poa=http://${IP[$n]}:8282/

# --- durable trust state. The default (/tmp inside the container) lives in the
# container's writable layer: it survives a restart but NOT a recreation, which
# would reset the B6 observer epoch and the EMA. /var/lib/sui-om2m is
# bind-mounted from the host's ~/sui-runtime-config/state by the v8 cutover.
trust.ema.persist.path=/var/lib/sui-om2m/trust-ema.properties
trust.epoch.persist.path=/var/lib/sui-om2m/trust-ema.properties.epoch
EOF
}

gen_mappings_das() {  # node
  local n=$1 o r
  cat <<EOF
# sui.mappings.properties for $n (${IP[$n]}) - the DAS / GRANT node
# $STAMP
#
# Loaded by java.util.Properties: EVERY ':' in a KEY is escaped as \\: (a bare
# ':' ends the key - the C6 bug; see config/sui.mappings.properties). Values are
# not escaped. Key forms:
#   addr.<originator>=<sui address>
#   token.<originator>::<resource-id>=<CapToken id>
#
# v8 A3/A4: requester = transaction sender and token.owner must equal it. This
# DAS signs with $n's key, so both originators map to $n's address and every
# token below was minted with owner=${ADDR[$n]}.

EOF
  for o in "${ORIGINATORS[@]}"; do
    printf '%s=%s\n' "$(esc_key "addr.$o")" "${ADDR[$n]}"
  done
  echo
  for r in "${RESOURCES[@]}"; do
    case "$r" in
      "$RES_PROTECTED_CNT") echo "# $r - legacy NOTIFY-path container (bench/provision_das.sh step 5)";;
      "$RES_DAC_AE")        echo "# $r - C2 DAC-protected AE; key is the NON-hierarchical ri the DAS receives";;
    esac
    for o in "${ORIGINATORS[@]}"; do
      printf '%s=%s\n' "$(esc_key "token.$o::$r")" "${TOKEN_FOR[$r]}"
    done
  done
}

gen_mappings_peer() {  # node
  local n=$1
  cat <<EOF
# sui.mappings.properties for $n (${IP[$n]}) - intentionally NO mappings
# $STAMP
#
# Every v8 CapToken is owned by $DAS_NODE (${ADDR[$DAS_NODE]}). Under A3/A4 the
# access PTB's requester is the transaction sender and validate_for_use asserts
# token.owner == sender, and Sui will not even accept another address's owned
# object as a transaction input. A DAS on $n signs with $n's key, so any token
# entry here could only fail - on-chain, after spending gas.
#
# With no entry, SuiDasService answers ACCESS_DENIED locally ("No Sui mapping
# for originator=...") without touching the chain: the intended fail-closed path.
# SuiConfig.load() treats the file as optional; it is emitted anyway so the
# bind-mount source exists and the absence of mappings is explicit.
#
# Cross-node denial test (proofs/05_policy.sh style) - opt-in only, expected to
# DENY (rejected input / E_NOT_TOKEN_OWNER), never GRANT:
#addr.Csensor-001=${ADDR[$n]}
#token.Csensor-001\\:\\:$RES_PROTECTED_CNT=$TOKEN_SUI_PROTECTED_CNT
EOF
}

gen_env_fragment() {
  cat <<EOF
# env.v8.sh - scripts/env.sh-compatible fragment for the v8 deployment.
# $STAMP
# Source it AFTER scripts/env.sh (or merge it in by hand-review); scripts/env.sh itself is not touched.
export PKG_V8=$PKG_V8

# Shared registries (+ initial shared versions)
export IDENTITY_REG=$ID_REG
export IDENTITY_REG_ISV=${ID_REG_ISV:-}
export TRUST_REG=$TRUST_REG
export TRUST_REG_ISV=${TRUST_REG_ISV:-}
export POLICY_REG=$POLICY_REG
export POLICY_REG_ISV=${POLICY_REG_ISV:-}
export AUDIT_TRAIL=$AUDIT_TRAIL
export AUDIT_TRAIL_ISV=${AUDIT_TRAIL_ISV:-}

# Publisher-owned capabilities
export ISSUER_CAP=$ISSUER_CAP
export ID_ADMIN_CAP=$ID_ADMIN_CAP
export TR_ADMIN_CAP=$TRUST_ADMIN_CAP
export POL_ADMIN_CAP=$POL_ADMIN_CAP
export AUDIT_ADMIN_CAP=$AUDIT_ADMIN_CAP
export UPGRADE_CAP=$UPGRADE_CAP

# Constants / nodes
export CLOCK=0x6
export ME=$PUBLISHER
export GAS=20000000
$(for n in "${NODES[@]}"; do echo "export ${n^^}=${ADDR[$n]}"; done)

# Failover
export CLUSTER=$CLUSTER
export CLUSTER_ISV=${CLUSTER_ISV:-}
export CLUSTER_CAP=$CLUSTER_ADMIN_CAP

# Per-node trust AdminCaps (owned by each node)
$(for n in "${NODES[@]}"; do echo "export ADMINCAP_${n^^}=${CAP[$n]}"; done)

# CapTokens (owned by $DAS_NODE)
export CAP_TOKEN_${DAS_NODE^^}=$TOKEN_SUI_PROTECTED_CNT
export TOKEN=$TOKEN_SUI_PROTECTED_CNT
export CAP_TOKEN_${DAS_NODE^^}_DAC=$TOKEN_SUI_DAC_AE
EOF
}

# ---------------------------------------------------------------- write
mkdir -p "$OUT_DIR"
for n in "${NODES[@]}"; do
  d="$OUT_DIR/nodes/$n"; mkdir -p "$d"
  gen_sui_properties "$n" > "$d/sui.properties"
  if [ "$n" = "$DAS_NODE" ]; then gen_mappings_das "$n"; else gen_mappings_peer "$n"; fi > "$d/sui.mappings.properties"
  echo "wrote $d/sui.properties, $d/sui.mappings.properties"
done
gen_env_fragment > "$OUT_DIR/env.v8.sh"
echo "wrote $OUT_DIR/env.v8.sh"

# ---------------------------------------------------------------- env.sh diff-style summary
echo
echo "== env.v8.sh vs $(basename "$ENV_SH") (summary; $ENV_SH is NOT modified)"
python3 - "$ENV_SH" "$OUT_DIR/env.v8.sh" <<'PY'
import re, sys, os
def load(p):
    d = {}
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            m = re.match(r"\s*export\s+([A-Za-z_][A-Za-z0-9_]*)=(\S*)", line)
            if m: d[m.group(1)] = m.group(2)   # last definition wins, as in bash
    return d
old, new = load(sys.argv[1]), load(sys.argv[2])
for k in new:
    if k not in old:            print(f"  + {k}={new[k]}   (new)")
    elif old[k] != new[k]:      print(f"  - {k}={old[k]}\n  + {k}={new[k]}")
    else:                       print(f"    {k}={new[k]}   (unchanged)")
for k in old:
    if k not in new:            print(f"  ! {k}={old[k]}   (NOT in fragment - stays as-is; see note)")
print("  note: PKG is the retired v1..v6 root; PKG_V7 is used by proofs/*.sh and must be retargeted to PKG_V8")
print("        deliberately (the fragment does not alias it); MN2 is not a v8 node.")
PY

# ---------------------------------------------------------------- optional v7 -> v8 key diff
if [ -n "$V7_DIR" ]; then
  for n in "${NODES[@]}"; do
    [ -f "$V7_DIR/$n/sui.properties" ] || continue
    echo; echo "== $n: live v7 sui.properties -> generated v8 (keys)"
    python3 - "$V7_DIR/$n/sui.properties" "$OUT_DIR/nodes/$n/sui.properties" <<'PY'
import sys
def keys(p):
    out = {}
    for l in open(p, encoding="utf-8"):
        l = l.strip()
        if not l or l[0] in "#!": continue
        k, _, v = l.partition("=")
        out[k.strip()] = v.strip()
    return out
a, b = keys(sys.argv[1]), keys(sys.argv[2])
for k in sorted(set(a) | set(b)):
    if k not in b:   print(f"  - {k}   (DROPPED - check it is not needed)")
    elif k not in a: print(f"  + {k}={b[k]}")
    elif a[k] != b[k]: print(f"  ~ {k}: {a[k]} -> {b[k]}")
PY
  done
fi

# ---------------------------------------------------------------- self-check
echo
echo "== self-check: re-parse every generated file with java.util.Properties semantics"
NODE_ROWS=$(for n in "${NODES[@]}"; do printf '   ("%s", "%s", "%s", "%s"),
' "$n" "${ADDR[$n]}" "${IP[$n]}" "${CAP[$n]}"; done)
EXPECT_JSON=$(python3 - <<PY
import json
print(json.dumps({
 "nodes": {n: {"addr": a, "ip": i, "cap": c} for n, a, i, c in [
$NODE_ROWS
   ]},
 "das": "$DAS_NODE",
 "originators": ["admin:admin", "Csensor-001"],
 "tokens": {"$RES_PROTECTED_CNT": "$TOKEN_SUI_PROTECTED_CNT", "$RES_DAC_AE": "$TOKEN_SUI_DAC_AE"},
 "shared": {"sui.package.id": "$CALL_PKG", "sui.package.original.id": "$PKG_V8", "sui.identity.registry.id": "$ID_REG",
            "sui.trust.registry.id": "$TRUST_REG", "sui.policy.registry.id": "$POLICY_REG",
            "sui.audit.trail.id": "$AUDIT_TRAIL", "sui.failover.cluster.id": "$CLUSTER",
            "sui.clock.id": "0x6", "sui.graphql.url": "$GRAPHQL_URL", "sui.use.native.rpc": "true",
            "sui.das.precheck.enabled": "true", "sui.das.deny.audit.flush.enabled": "$DENY_FLUSH",
            "sui.das.deny.log.path": "/var/lib/sui-om2m/deny-log.jsonl"},
}))
PY
)
python3 - "$OUT_DIR" "$EXPECT_JSON" <<'PY'
import json, sys, os
out, exp = sys.argv[1], json.loads(sys.argv[2])

def load_java_properties(text):
    """java.util.Properties.load(Reader) semantics: logical lines with odd
    trailing-backslash continuation, '#'/'!' comments, key ends at the first
    UNESCAPED '=', ':' or whitespace, escapes \\t \\n \\r \\f \\uXXXX, any other
    \\x -> x. Returns (dict, ordered list of keys)."""
    props, order = {}, []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].lstrip(" \t\f"); i += 1
        if not line or line[0] in "#!": continue
        while True:  # continuation: odd number of trailing backslashes
            bs = len(line) - len(line.rstrip("\\"))
            if bs % 2 == 1 and i < len(lines):
                line = line[:-1] + lines[i].lstrip(" \t\f"); i += 1
            else: break
        # key end
        j, n = 0, len(line)
        while j < n:
            ch = line[j]
            if ch == "\\": j += 2; continue
            if ch in "=: \t\f": break
            j += 1
        raw_key = line[:j]
        k = j
        while k < n and line[k] in " \t\f": k += 1
        if k < n and line[k] in "=:": k += 1
        while k < n and line[k] in " \t\f": k += 1
        key, val = unescape(raw_key), unescape(line[k:])
        props[key] = val; order.append(key)
    return props, order

def unescape(s):
    r, j = [], 0
    while j < len(s):
        c = s[j]
        if c == "\\" and j + 1 < len(s):
            d = s[j + 1]
            if d == "u":
                r.append(chr(int(s[j + 2:j + 6], 16))); j += 6; continue
            r.append({"t": "\t", "n": "\n", "r": "\r", "f": "\f"}.get(d, d)); j += 2; continue
        r.append(c); j += 1
    return "".join(r)

fail = []
def check(cond, msg):
    if not cond: fail.append(msg)

# 0) the checker itself must catch the C6 bug (negative control)
bad, _ = load_java_properties("token.admin:admin::/in-cse/in-name/sui-protected-cnt=0xabc\naddr.admin:admin=0xdef\n")
assert "token.admin" in bad and bad["token.admin"] == "admin::/in-cse/in-name/sui-protected-cnt=0xabc", bad
assert "addr.admin" in bad and bad["addr.admin"] == "admin=0xdef", bad
good, _ = load_java_properties("token.admin\\:admin\\:\\:/in-cse/in-name/sui-protected-cnt=0xabc\n")
assert good == {"token.admin:admin::/in-cse/in-name/sui-protected-cnt": "0xabc"}, good
print("  negative control: mis-escaped line parses as key 'token.admin' (C6 reproduced) -> checker is live")

weights = ["heartbeat", "malformed", "rate", "clock", "denied_burst", "historical", "inactive", "garbage"]
for node, facts in exp["nodes"].items():
    d = os.path.join(out, "nodes", node)
    for fn in ("sui.properties", "sui.mappings.properties"):
        raw = open(os.path.join(d, fn), "rb").read()
        check(b"\r" not in raw, f"{node}/{fn}: contains CR")
    p, order = load_java_properties(open(os.path.join(d, "sui.properties"), encoding="utf-8").read())
    check(len(order) == len(set(order)), f"{node}/sui.properties: duplicate keys")
    for k in ("sui.cli.path", "sui.package.id", "sui.identity.registry.id", "sui.trust.registry.id",
              "sui.policy.registry.id", "sui.audit.trail.id", "sui.node.address", "mqtt.broker.url"):
        check(p.get(k, "").strip() != "", f"{node}: required key {k} missing/empty (SuiConfig.req would throw)")
    for k, v in exp["shared"].items():
        check(p.get(k) == v, f"{node}: {k}={p.get(k)!r}, expected {v!r}")
    check(p.get("sui.node.address") == facts["addr"], f"{node}: wrong sui.node.address")
    check(p.get("trust.admin.cap.id") == facts["cap"], f"{node}: trust.admin.cap.id is not this node's OWN cap")
    check(p.get("mqtt.broker.url") == f"tcp://{facts['ip']}:1883", f"{node}: mqtt.broker.url not own IP")
    s = sum(float(p.get(f"trust.weight.{w}", "nan")) for w in weights)
    check(abs(s - 100.0) < 0.01, f"{node}: trust weights sum {s} != 100 (TrustConfig.validate would throw)")
    others = [f["cap"] for n2, f in exp["nodes"].items() if n2 != node]
    check(p.get("trust.admin.cap.id") not in others, f"{node}: shares a trust cap with a peer")

    m, morder = load_java_properties(open(os.path.join(d, "sui.mappings.properties"), encoding="utf-8").read())
    if node == exp["das"]:
        want = {}
        for o in exp["originators"]:
            want[f"addr.{o}"] = facts["addr"]
            for r, t in exp["tokens"].items():
                want[f"token.{o}::{r}"] = t
        check(m == want, f"{node}: mappings differ from expected:\n    got  {m}\n    want {want}")
        # Replay SuiConfig.load(): substring(6), indexOf("::"), split.
        for k, v in m.items():
            if k.startswith("token."):
                rest = k[6:]; sep = rest.find("::")
                check(sep > 0, f"{node}: token key lost its '::' -> {k!r} (C6)")
                if sep > 0:
                    o, r = rest[:sep], rest[sep + 2:]
                    check(o in exp["originators"] and r in exp["tokens"], f"{node}: token key splits to ({o!r},{r!r})")
                    print(f"  {node}: token key round-trips: originator={o!r} resource={r!r} -> {v}")
            elif k.startswith("addr."):
                print(f"  {node}: addr key round-trips:  originator={k[5:]!r} -> {v}")
            else:
                check(False, f"{node}: stray mapping key {k!r} (a mis-escaped line?)")
    else:
        check(m == {}, f"{node}: expected no active mappings, got {m}")
        print(f"  {node}: no active mappings (fail-closed by design)")
    print(f"  {node}: sui.properties {len(p)} keys parsed OK; trust.admin.cap.id={p.get('trust.admin.cap.id')}")

if fail:
    print("SELF-CHECK FAILED:"); [print("  - " + f) for f in fail]; sys.exit(1)
print("SELF-CHECK OK (python, java.util.Properties semantics)")
PY

# Second opinion from the real java.util.Properties when a JDK >= 11 is available.
if command -v java >/dev/null 2>&1 && java -version 2>&1 | grep -qE 'version "(1[1-9]|[2-9][0-9])'; then
  jt=$(mktemp -d)
  cat > "$jt/PropsCheck.java" <<'JAVA'
import java.io.*; import java.util.*;
public class PropsCheck {
  public static void main(String[] a) throws Exception {
    int bad = 0;
    for (String f : a) {
      Properties p = new Properties();
      try (Reader r = new InputStreamReader(new FileInputStream(f), "ISO-8859-1")) { p.load(r); }
      for (String k : p.stringPropertyNames()) {
        if (k.startsWith("token.")) {
          String rest = k.substring(6); int sep = rest.indexOf("::");
          if (sep <= 0) { System.out.println("  JAVA: BROKEN token key " + k); bad++; }
          else System.out.println("  JAVA: " + f.replaceAll(".*nodes/", "") + " token " + rest.substring(0, sep) + " :: " + rest.substring(sep + 2));
        } else if (k.equals("addr.admin") || k.equals("token.admin")) { System.out.println("  JAVA: C6 junk key " + k); bad++; }
      }
    }
    if (bad > 0) { System.out.println("JAVA SELF-CHECK FAILED"); System.exit(1); }
    System.out.println("SELF-CHECK OK (real java.util.Properties)");
  }
}
JAVA
  java "$jt/PropsCheck.java" "$OUT_DIR"/nodes/*/sui.mappings.properties || { rm -rf "$jt"; die "java self-check failed"; }
  rm -rf "$jt"
else
  echo "  (no JDK >= 11 on PATH - real-Java cross-check skipped; the python check above is authoritative)"
fi

echo
echo "OK: config generated under $OUT_DIR. Review, then install per ROLLOUT_V8.md phase E (durable ~/sui-runtime-config/ first, then /tmp)."
