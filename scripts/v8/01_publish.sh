#!/usr/bin/env bash
# 01_publish.sh - fresh-publish the v8 om2m_access package and record every ID.
#
# Run in WSL as the publisher (active address 0xb87fb2af...). The key never
# leaves that machine.
#
#   scripts/v8/01_publish.sh            # DRY RUN (default): build, test, simulate
#   scripts/v8/01_publish.sh --execute  # really publish (signs + spends gas)
#   scripts/v8/01_publish.sh --execute --fresh-publish
#                                       # required once deploy/v8/deployment.env exists
#
# SINCE v9 (2026-11-10): the live package is a compatible UPGRADE of this v8
# publish and its types still carry the v8 id, so deploy/v8/deployment.env must
# never be overwritten. A second --execute would create a new, unrelated
# deployment (new registries, new caps, no council). It is refused unless
# --fresh-publish is given, and then writes to deploy/fresh-<UTC time>/ instead.
# Changes to the live system go through scripts/v9/02_upgrade.sh and the council.
#
# Why a FRESH publish and not an upgrade: A6/A7 change function signatures and
# visibility across 5 of 8 modules, which a compatible upgrade forbids.
#
# Output (execute mode):
#   deploy/v8/publish.json   raw CLI effects (kept for the evidence trail)
#   deploy/v8/deployment.env THE single source of truth for every v8 ID.
#                            Everything downstream is generated from it.
set -euo pipefail

MODE="${1:---dry-run}"
PUBLISHER="0xb87fb2af21e29dd292d5b557b92d95a544794a589620f4b437f2247f075d6a1e"
GAS_BUDGET="${GAS_BUDGET:-500000000}"   # 0.5 SUI cap; unused gas is refunded

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO/deploy/v8"
if [ "$MODE" = "--execute" ] && [ -f "$OUT/deployment.env" ]; then
  if [ "${2:-}" != "--fresh-publish" ]; then
    echo "REFUSED: deploy/v8/deployment.env already exists and the live v9 package depends on it." >&2
    echo "  Upgrading the live system:   scripts/v9/02_upgrade.sh (see ROLLOUT_V9.md)" >&2
    echo "  Admin actions on v9:         scripts/v9/council.sh propose|approve|execute|status" >&2
    echo "  A deliberate, separate deployment: $0 --execute --fresh-publish" >&2
    exit 3
  fi
  OUT="$REPO/deploy/fresh-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "== --fresh-publish: new deployment recorded in $OUT (deploy/v8 untouched) =="
fi
cd "$REPO/move"
mkdir -p "$OUT"

active=$(sui client active-address)
[ "$active" = "$PUBLISHER" ] || { echo "FATAL: active address is $active, expected publisher $PUBLISHER"; exit 1; }
[ "$(sui client active-env)" = "testnet" ] || { echo "FATAL: active env is not testnet"; exit 1; }

# A Move.lock written by the Windows sui CLI uses backslash subdirs
# (crates\sui-framework\...), which the Linux CLI cannot resolve. It fails as a
# baffling "Invalid directory" dependency error, so catch it up front.
if grep -q "subdir = '.*\\\\" Move.lock 2>/dev/null; then
  echo "FATAL: move/Move.lock contains Windows path separators (written by the Windows sui CLI)."
  echo "       Restore it with: git checkout HEAD -- move/Move.lock"
  exit 1
fi

echo "== 1. tests must pass before anything is published =="
sui move test 2>&1 | tail -3
sui move test 2>&1 | grep -q "Test result: OK" || { echo "FATAL: move tests failing"; exit 1; }

# Published.toml still records v7. The CLI refuses to publish a package it
# believes is already published, so set the v7 record aside (same procedure as
# the v6 -> v7 republish, which left Published.toml.v6-backup behind).
if [ -f Published.toml ] && grep -q "0x56601695204350f97a90cb283da19682aa6fcaeab876ea736060afea40213d43" Published.toml; then
  cp Published.toml Published.toml.v7-backup
  rm Published.toml
  echo "== set aside v7 Published.toml -> Published.toml.v7-backup =="
fi

if [ "$MODE" != "--execute" ]; then
  echo "== 2. DRY RUN: simulating publish (nothing is signed or spent) =="
  sui client publish --dry-run --gas-budget "$GAS_BUDGET" --json > "$OUT/publish.dryrun.json"
  python3 - "$OUT/publish.dryrun.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
e=d.get("effects",{}); st=e.get("status",{})
g=e.get("gasUsed",{})
cost=int(g.get("computationCost",0))+int(g.get("storageCost",0))-int(g.get("storageRebate",0))
print("status:", st.get("status"), st.get("error",""))
print(f"estimated net gas: {cost} MIST = {cost/1e9:.4f} SUI")
for c in d.get("objectChanges",[]):
    print(" ", c.get("type"), c.get("objectType", c.get("packageId","")))
PY
  # put the v7 record back: a dry run must leave the tree exactly as it was
  [ -f Published.toml.v7-backup ] && [ ! -f Published.toml ] && cp Published.toml.v7-backup Published.toml
  echo "DRY RUN complete. Re-run with --execute to publish for real."
  exit 0
fi

echo "== 2. PUBLISHING v8 (signed by $PUBLISHER) =="
sui client publish --gas-budget "$GAS_BUDGET" --json > "$OUT/publish.json"

python3 - "$OUT/publish.json" "$OUT/deployment.env" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
st=d["effects"]["status"]
if st.get("status")!="success":
    sys.exit(f"FATAL: publish failed: {st}")
want={  # (module, type) -> env name. Two different AdminCap types exist.
 ("trust","TrustRegistry"):"TRUST_REG", ("identity","Registry"):"ID_REG",
 ("policy","PolicyRegistry"):"POLICY_REG", ("audit","AuditTrail"):"AUDIT_TRAIL",
 ("trust","AdminCap"):"TRUST_ADMIN_CAP", ("identity","AdminCap"):"ID_ADMIN_CAP",
 ("policy","PolicyAdminCap"):"POL_ADMIN_CAP", ("audit","AuditAdminCap"):"AUDIT_ADMIN_CAP",
 ("cap_token","IssuerCap"):"ISSUER_CAP", ("package","UpgradeCap"):"UPGRADE_CAP",
}
env={"DIGEST":d["digest"]}
for c in d["objectChanges"]:
    if c["type"]=="published":
        env["PKG_V8"]=c["packageId"]; continue
    if c["type"]!="created": continue
    t=c["objectType"].split("<")[0].split("::")
    key=want.get((t[1],t[2]))
    if not key: continue
    env[key]=c["objectId"]
    sh=c["owner"].get("Shared") if isinstance(c["owner"],dict) else None
    if sh: env[key+"_ISV"]=str(sh["initial_shared_version"])
missing=[v for v in list(want.values())+["PKG_V8"] if v not in env]
if missing: sys.exit(f"FATAL: publish effects missing {missing} - inspect publish.json")
with open(sys.argv[2],"w") as f:
    f.write("# v8 deployment - GENERATED by scripts/v8/01_publish.sh. Do not hand-edit.\n")
    f.write("# Single source of truth: env.sh and every node's sui.properties derive from this.\n")
    for k in sorted(env): f.write(f"export {k}={env[k]}\n")
print(open(sys.argv[2]).read())
PY
echo "OK: v8 published. IDs recorded in $OUT/deployment.env"
