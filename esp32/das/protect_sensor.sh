#!/usr/bin/env bash
# protect_sensor.sh - put one ESP32 under the on-chain access check (v9).
#
# Run from Git Bash on the laptop (VPN up), from anywhere in the repo. Since v9
# the publisher no longer holds PolicyAdminCap or IssuerCap: the 3-of-5 council
# does. So every chain write here is a council proposal, proposed, approved and
# executed through scripts/v9/council.sh, each step signed ON a member Pi by that
# node's own key. No key leaves a node and no publisher cap is used.
#
#   esp32/das/protect_sensor.sh <device> <reader-originator> [token-owner-node ...]
#   esp32/das/protect_sensor.sh esp32-dht-01 Cesp32-reader-01 rpi2
#   esp32/das/protect_sensor.sh esp32-dht-01 Cesp32-reader-01        (a token for every active node)
#
# Environment:
#   SIGNERS="rpi1 rpi3 rpi4"  the council members that propose (first) and approve;
#                             at least the council threshold (3) of them
#   SKIP_POLICY=1             the policy is already set; only mint tokens
#   POLICY_MIN_TRUST (50), DAYS (30), MAX_USES (100000)
#
# What it does
#   1. council policy-set  resource /in-cse/C<device>, min_trust, ops mask READ (1)
#   2. council token-mint  one READ token per owner node, owned by that node's address
#   3. records, per owner node, the two mapping lines its DAS needs in
#      deploy/v9/mappings/<node>.properties (03_gen_config.sh appends them)
#
# Why these values
#   - The device is an AE created by the bridge with originator C<device>, so
#     its resource id is /in-cse/C<device> on EVERY node, and that is what
#     OM2M's DynamicAuthorizationSelector sends the DAS (targetedResourceID).
#   - The DAS signs as the node it runs on (requester = signer = token owner).
#     Data lives on whichever node is PARENT, so a node can only serve a
#     protected read while it holds its own token.
#   - READ only: an ordinary RETRIEVE maps to OP_READ (1); DELETE is then
#     refused by cap_token::E_OP_NOT_ALLOWED - found by the DAS's free
#     simulation and never submitted (F3), so a denial costs no gas.
set -euo pipefail
DEV=${1:?device}; READER=${2:?reader originator (must start with C, and not be C<device>)}; shift 2
OWNERS=${*:-}
[[ "$READER" == C* && "$READER" != "C$DEV" ]] || { echo "reader must start with C and differ from C$DEV"; exit 1; }
REPO=$(cd "$(dirname "$0")/../.." && pwd)
COUNCIL_SH="$REPO/scripts/v9/council.sh"
# shellcheck source=../../scripts/v9/lib.sh
. "$REPO/scripts/v9/lib.sh"
[[ -n "${COUNCIL:-}" ]] || die "no COUNCIL in deploy/v9/deployment.env"
[[ -n "$OWNERS" ]] || OWNERS="${V9_NODES[*]}"
read -r -a SIG <<<"${SIGNERS:-rpi1 rpi3 rpi4}"
(( ${#SIG[@]} >= 3 )) || die "SIGNERS needs at least 3 council members (threshold 3)"
MIN=${POLICY_MIN_TRUST:-50}; DAYS=${DAYS:-30}; MAX_USES=${MAX_USES:-100000}
RID="/in-cse/C$DEV"
addr_of() { inv_require "$1"; echo "${INV_ADDR[$1]}"; }
for n in $OWNERS; do [[ -n "$(addr_of "$n")" ]] || die "$n has no sui_address in deploy/inventory.tsv"; done

echo "council $COUNCIL   resource $RID   reader $READER"
echo "signers: ${SIG[*]}   token owners: $OWNERS"

# vote <action> [target] [text] [v1] [v2] [v3]: propose by SIG[0], approve by
# the rest, execute by SIG[0]. Prints the execute output (digest, created ids).
vote() {
  local out pid s
  out=$(bash "$COUNCIL_SH" propose "${SIG[0]}" "$@") || { echo "$out"; die "propose failed"; }
  echo "$out" | sed 's/^/   /' >&2
  pid=$(sed -n 's/^proposal_id //p' <<<"$out" | tail -1)
  [[ -n "$pid" ]] || die "no proposal id in the propose output"
  for s in "${SIG[@]:1}"; do
    out=$(bash "$COUNCIL_SH" approve "$s" "$pid") || { echo "$out"; die "approve by $s failed"; }
    echo "$out" | sed 's/^/   /' >&2
  done
  out=$(bash "$COUNCIL_SH" execute "${SIG[0]}" "$pid") || { echo "$out"; die "execute failed"; }
  echo "$out" | sed 's/^/   /' >&2
  echo "proposal $pid"; echo "$out"
}

if [[ -z "${SKIP_POLICY:-}" ]]; then
  echo "== 1. council policy-set $RID min_trust $MIN ops READ"
  vote policy-set 0x0 "$RID" "$MIN" 1 0 >/dev/null
fi

EXPIRY=$(( ($(date +%s) + DAYS*24*3600) * 1000 ))
declare -A TOK
for n in $OWNERS; do
  echo "== 2. council token-mint READ for $n ($(addr_of "$n" | cut -c1-12)...)"
  out=$(vote token-mint "$(addr_of "$n")" "$RID" "$EXPIRY" "$MAX_USES" 1)
  TOK[$n]=$(sed -n 's/^created CapToken //p' <<<"$out" | tail -1)
  [[ -n "${TOK[$n]}" ]] || die "minted, but no CapToken id in the execute output"
done

# 3. Record each owner's two lines in deploy/v9/mappings/<node>.properties (committed).
# scripts/v8/03_gen_config.sh appends that file to the node's generated
# sui.mappings.properties, so the lines survive every config regeneration.
# Keep the backslashes: java.util.Properties splits keys on an unescaped ':'.
MAPDIR="$REPO/deploy/v9/mappings"; mkdir -p "$MAPDIR"
for n in $OWNERS; do
  f="$MAPDIR/$n.properties"
  akey="addr.$READER"; tkey="token.$READER\:\:$RID"
  [[ -f "$f" ]] || printf '# %s: council-minted DAS mappings (esp32/das/protect_sensor.sh). Committed;\n# appended to the generated sui.mappings.properties by scripts/v8/03_gen_config.sh.\n' "$n" > "$f"
  # replace an earlier entry for the same key (a re-mint), keep everything else
  grep -vF -e "$akey=" -e "$tkey=" "$f" > "$f.tmp" || true; mv "$f.tmp" "$f"
  printf '%s=%s\n%s=%s\n' "$akey" "$(addr_of "$n")" "$tkey" "${TOK[$n]}" >> "$f"
  echo "== 3. recorded in deploy/v9/mappings/$n.properties:"; sed 's/^/   /' "$f"
done
echo
echo "Next: scripts/v8/04_cutover.sh config, then ONLY=\"$OWNERS\" scripts/v8/04_cutover.sh redeploy"
echo "(mappings are read once, at plugin start; the bridge re-provisions the AE after the wipe)."
