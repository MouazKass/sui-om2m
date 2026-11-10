#!/usr/bin/env bash
# upgrade_multisig.sh - one multisig-signed package upgrade, end to end.
#
# Run from Git Bash on the laptop:
#   scripts/v9/upgrade_multisig.sh [--no-execute] <signer> <signer> <signer> ...
#
# <signer> is a label from MS_LABELS in deploy/v9/multisig.env, e.g.
#   publisher   signs in WSL with the publisher key (never leaves WSL)
#   rpi1 ...    signs ON that Pi with its dedicated upgrade key, in an offline
#               container (scripts/v9/upgrade_signer.sh); only the signature returns
# Any other label is an off-machine signer (V9_SIGNERS.md section 4): put their
# returned suiSignature in SIG_<label>=... in the environment.
#
# Steps (each signature covers the exact bytes built in step 1):
#   1. WSL: 02_upgrade.sh build   -> $V9_DIR/upgrade.tx.b64 (multisig as sender)
#   2. each signer signs those bytes on its own machine
#   3. WSL: 02_upgrade.sh combine -> $V9_DIR/upgrade.multisig (refuses < MS_THRESHOLD)
#   4. WSL: 02_upgrade.sh execute (typed confirmation, or CONFIRM='upgrade <cap> to <label>')
# --no-execute stops after 3; the signatures are kept in $V9_DIR/upgrade.sigs.
#
# Passed through to 02_upgrade.sh: UPGRADE_LABEL PKG_DIR UPGRADE_CAP_ID SKIP_PKG_CHECK
# GAS_BUDGET CONFIRM V9_DIR (a Git Bash path; translated for WSL).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "FATAL: $*" >&2; exit 1; }
say() { echo; echo "=== $* ==="; }
EXECUTE=yes
[ "${1:-}" = "--no-execute" ] && { EXECUTE=no; shift; }
[ $# -ge 1 ] || { sed -n '2,22p' "$0"; exit 1; }

export MSYS_NO_PATHCONV=1
WSL_DISTRO="${WSL_DISTRO:-Ubuntu}"
# Git Bash path -> WSL /mnt path
wslp() { local w; w=$(cygpath -m "$1"); printf '/mnt/%s%s' "$(printf '%s' "${w:0:1}" | tr 'A-Z' 'a-z')" "${w:2}"; }
V9_DIR="${V9_DIR:-$REPO/deploy/v9}"; V9_DIR=$(cd "$V9_DIR" && pwd)
MS_ENV="$V9_DIR/multisig.env"
[ -f "$MS_ENV" ] || die "no $MS_ENV; run scripts/v9/00_multisig.sh first"
# shellcheck disable=SC1090
. "$MS_ENV"
[ -n "${MS_LABELS:-}" ] || die "$MS_ENV has no MS_LABELS; re-derive with 00_multisig.sh -l"
read -r -a LABELS <<<"$MS_LABELS"; read -r -a PKS <<<"$MS_PKS"

# Run 02_upgrade.sh (or any command) in WSL with the pass-through env.
in_wsl() {
  local envs="V9_DIR=$(printf %q "$(wslp "$V9_DIR")")" v
  for v in UPGRADE_LABEL PKG_DIR UPGRADE_CAP_ID SKIP_PKG_CHECK GAS_BUDGET CONFIRM; do
    if [ -n "${!v:-}" ]; then
      local val="${!v}"; [ "$v" = PKG_DIR ] && val=$(wslp "$val")
      envs+=" $v=$(printf %q "$val")"
    fi
  done
  wsl -d "$WSL_DISTRO" --exec bash -lc "cd $(printf %q "$(wslp "$REPO")") && export $envs && $*"
}

# Check every requested signer is a member, once, before anything is built.
declare -A IDX=()
for s in "$@"; do
  i=-1; for j in "${!LABELS[@]}"; do [ "${LABELS[$j]}" = "$s" ] && i=$j; done
  [ "$i" -ge 0 ] || die "'$s' is not a multisig signer (members: $MS_LABELS)"
  [ -z "${IDX[$s]:-}" ] || die "signer '$s' given twice"
  IDX[$s]=$i
done
[ $# -ge "$MS_THRESHOLD" ] || die "need at least $MS_THRESHOLD signers, got $#"

say "1. build the unsigned upgrade (multisig $UPGRADE_MULTISIG)"
in_wsl "bash scripts/v9/02_upgrade.sh build"
TX_FILE="$V9_DIR/upgrade.tx.b64"
[ -s "$TX_FILE" ] || die "build produced no $TX_FILE"
TX=$(tr -d '[:space:]' < "$TX_FILE")
echo "tx sha256 $(printf '%s' "$TX" | sha256sum | cut -c1-16)"

say "2. collect signatures, each on its signer's own machine"
. "$REPO/scripts/lib/inventory.sh"; inv_load
SIGS=(); : > "$V9_DIR/upgrade.sigs"
for s in "$@"; do
  if [ "$s" = publisher ]; then
    sig=$(in_wsl "\"\${SUI:-\$HOME/sui-cli/1.83.1/sui}\" keytool --json sign --address 0xb87fb2af21e29dd292d5b557b92d95a544794a589620f4b437f2247f075d6a1e --data $TX" \
          | python3 -c 'import json,sys; print(json.load(sys.stdin)["suiSignature"])')
  elif [ -n "${INV_IP[$s]:-}" ]; then
    sig=$(bash "$REPO/scripts/v9/upgrade_signer.sh" sign "$s" "$TX_FILE")
  else
    v="SIG_$s"; sig="${!v:-}"; [ -n "$sig" ] || die "off-machine signer $s: set $v to their suiSignature"
  fi
  # The signature must come from the key recorded for that label.
  got=$(python3 -c 'import base64,sys; r=base64.b64decode(sys.argv[1]); print(base64.b64encode(r[:1]+r[65:]).decode())' "$sig")
  [ "$got" = "${PKS[${IDX[$s]}]}" ] || die "signature from $s is by key $got, expected ${PKS[${IDX[$s]}]}"
  echo "  $s: signed (key ${got:0:12}...)"
  SIGS+=("$sig"); echo "$s $sig" >> "$V9_DIR/upgrade.sigs"
done

say "3. combine (threshold $MS_THRESHOLD of ${#PKS[@]})"
in_wsl "bash scripts/v9/02_upgrade.sh combine ${SIGS[*]}"

if [ "$EXECUTE" = no ]; then
  echo; echo "--no-execute: combined signature in $V9_DIR/upgrade.multisig; run 02_upgrade.sh execute in WSL"; exit 0
fi
say "4. execute"
[ -n "${CONFIRM:-}" ] || die "set CONFIRM='upgrade <cap> to <label>' (WSL has no terminal to type it into from here)"
in_wsl "bash scripts/v9/02_upgrade.sh execute"
