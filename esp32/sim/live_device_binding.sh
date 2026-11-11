#!/usr/bin/env bash
# live_device_binding.sh - v10 live proof: a protected read of a sensor is tied
# to the sensor's on-chain identity (V10_DESIGN.md). Run from Git Bash on the
# laptop; every on-chain write is a 3-of-5 council decision (scripts/v9/council.sh).
#
#   esp32/sim/live_device_binding.sh [bind|read|revoke|restore|fence|all]
#
#   bind     council: policy-bind-device <resource> -> <device address>
#   read     protected_read.sh on the parent: RETRIEVE GRANT, DELETE DENY
#   revoke   council: id-deregister <device>     (then: read -> DENY, abort 7)
#   restore  council: id-register <device> role 3 (then: read -> GRANT)
#   fence    free dry run on the parent: the v9 bytecode of policy::evaluate on
#            the bound resource aborts E_POLICY_MISSING (the policy now lives
#            in the binding, which only v10 code reads)
#
# Env: DEV (esp32-dht-01) DEV_ADDR READER (Cesp32-reader-01) PARENT (rpi2)
#      PROPOSER (rpi1) APPROVERS ("rpi3 rpi4")
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV=${DEV:-esp32-dht-01}
DEV_ADDR=${DEV_ADDR:-0x450ff708a3e0a8b01c20e4c0667d1627386d4710666f9db165d36c3c09208a6b}
RES="/in-cse/C$DEV"
READER=${READER:-Cesp32-reader-01}
PARENT=${PARENT:-rpi2}
PROPOSER=${PROPOSER:-rpi1}
read -r -a APPROVERS <<<"${APPROVERS:-rpi3 rpi4}"
COUNCIL="$REPO/scripts/v9/council.sh"
SSHCFG=(-F "$HOME/.ssh/config")
say() { echo; echo "=== $* ($(date -u +%FT%TZ)) ==="; }

decide() {   # council decision: propose, approve, execute
  local out pid
  out=$(bash "$COUNCIL" propose "$PROPOSER" "$@" 2>&1); echo "$out" | tail -3
  pid=$(awk '$1=="proposal_id"{print $2}' <<<"$out"); [ -n "$pid" ] || { echo "no proposal id"; exit 1; }
  for a in "${APPROVERS[@]}"; do bash "$COUNCIL" approve "$a" "$pid" 2>&1 | tail -2; done
  bash "$COUNCIL" execute "$PROPOSER" "$pid" 2>&1 | tail -3
  echo "proposal $pid executed"
}

read_on_parent() {
  ssh "${SSHCFG[@]}" "$PARENT" "bash -s -- $DEV $READER" < "$REPO/esp32/das/protected_read.sh"
}

fence() {
  # shellcheck disable=SC1091
  . "$REPO/deploy/v8/env.v8.sh"; . "$REPO/deploy/v9/deployment.env"
  local tok
  tok=$(grep -E "^token\.$READER\\\\:\\\\:$RES=" "$REPO/deploy/v9/mappings/$PARENT.properties" | cut -d= -f2)
  [ -n "$tok" ] || { echo "no token for $PARENT in deploy/v9/mappings"; exit 1; }
  echo "\$ [$PARENT] sui client ptb ... \$PKG_V9::policy::evaluate ... --dry-run   (token $tok)"
  ssh "${SSHCFG[@]}" "$PARENT" "docker exec om2m-active sui client ptb \
    --move-call $PKG_V9::identity::verify @$IDENTITY_REG --assign r1 \
    --move-call $PKG_V9::trust::require_min r1 @$TRUST_REG '\"$RES\"' 0 @0x6 --assign r2 \
    --move-call $PKG_V9::cap_token::validate_for_use r2 @$tok 1u8 @0x6 --assign r3 \
    --move-call $PKG_V9::policy::evaluate r3 @$POLICY_REG @$TRUST_REG @0x6 --assign r4 \
    --move-call $PKG_V9::evaluator::decide_and_log r4 @$AUDIT_TRAIL @0x6 \
    --gas-budget 50000000 --dry-run 2>&1" | grep -Eo 'MoveAbort.*|status.*|Error.*' | head -3
}

case "${1:-all}" in
  bind)    say "council: bind $RES to device $DEV_ADDR"; decide policy-bind-device "$DEV_ADDR" "$RES" ;;
  read)    say "protected read on $PARENT"; read_on_parent ;;
  revoke)  say "council: deregister device $DEV_ADDR"; decide id-deregister "$DEV_ADDR" ;;
  restore) say "council: re-register device $DEV_ADDR as $DEV (role 3)"; decide id-register "$DEV_ADDR" "$DEV" 3 ;;
  fence)   say "old v9 bytecode on the bound resource (free dry run)"; fence ;;
  all)
    "$0" bind; sleep 15; "$0" read; "$0" fence
    "$0" revoke; sleep 15; "$0" read
    "$0" restore; sleep 15; "$0" read ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
