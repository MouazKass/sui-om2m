# legacy_guard.sh - stop pre-v9 scripts that sign with the publisher's caps.
#
# Since 2026-11-10 the testbed runs v9 (ROLLOUT_V9.md): every identity, policy,
# issuer and cluster admin cap is held by the 3-of-5 council, and the publisher's
# genesis trust AdminCap was revoked by council proposal 5. A script that signs
# as the publisher now either aborts on-chain (E_GOVERNED / E_CAP_REVOKED, after
# paying gas) or, worse, acts on an old package line nobody uses any more.
#
#   source "$REPO/scripts/lib/legacy_guard.sh"
#   legacy_guard "<script name>" "<what it did>"
#
# Refuses (exit 3) whenever deploy/v9/deployment.env records a council.
# SUI_OM2M_ALLOW_LEGACY=1 overrides, for a deliberate run against an old
# deployment (e.g. reproducing historical evidence); it warns and continues.

legacy_guard() {
  local name=$1 what=${2:-}
  local repo
  repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  local v9env="$repo/deploy/v9/deployment.env"
  grep -q '^export COUNCIL=0x' "$v9env" 2>/dev/null || return 0   # no v9 deployment: nothing to guard
  if [ "${SUI_OM2M_ALLOW_LEGACY:-0}" = 1 ]; then
    echo "WARNING: $name is a pre-v9 script (SUI_OM2M_ALLOW_LEGACY=1 set, continuing)." >&2
    return 0
  fi
  cat >&2 <<EOF
REFUSED: $name is a pre-v9 script${what:+ ($what)}.
It signs with the publisher's caps, which no longer govern the live testbed:
  - identity, policy, token-issuer and cluster admin caps belong to the
    3-of-5 council (COUNCIL in deploy/v9/deployment.env);
  - the publisher's genesis trust cap was revoked by council proposal 5.
Do the same thing as a council proposal instead:
  scripts/v9/council.sh propose|approve|execute|status   (see ROLLOUT_V9.md)
To run it on purpose against an old deployment: SUI_OM2M_ALLOW_LEGACY=1 $name ...
EOF
  exit 3
}
