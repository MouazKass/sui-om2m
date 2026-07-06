#!/usr/bin/env bash
# CONCEPT 7 - SELF-EVOLVING TOKENS (EVO1-EVO7). A token's ops NARROW in place as
# trust falls across a tier boundary, via Dynamic Fields, same object id.
# Self-restoring: rpi3's trust is returned to its starting value at the end.
cd "$(dirname "$0")/.." && source scripts/env.sh

show_ops() {
  sui client object "$CAP_TOKEN_RPI3" --json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); f=d.get('content',{})
ops=int(float(f.get('allowed_ops',0)))
names=[]
if ops&1: names.append('READ')
if ops&2: names.append('WRITE')
if ops&4: names.append('DELETE')
if ops&8: names.append('ADMIN')
print('    token id    :', d.get('objectId'))
print('    allowed_ops :', ops, '=', '+'.join(names) if names else '(none)')
" 2>/dev/null
}
score_of() {
  sshpass -p user ssh user@10.25.96.201 \
    "docker exec om2m-active sui client call --package $PKG_V7 --module trust \
       --function score_of --args $TRUST_REG $RPI3 0x6 --dev-inspect 2>/dev/null" \
    | grep -iE "u64|value" | tail -1
}

echo
echo "################################################################################"
echo "#  CONCEPT 7 - SELF-EVOLVING TOKENS (demotion: permissions narrow in place)"
echo "################################################################################"
echo
echo "  Tier map:  score>=90 CUSTODIAN(15) | >=75 TRUSTED(7) | >=50 STANDARD(3) |"
echo "             >=25 BASIC(1) | <25 PROBATION(1)"
echo
echo "=== OPS BEFORE (rpi3 at high trust -> upper tier) ==="
echo
echo "\$ sui client object $CAP_TOKEN_RPI3 --json"
echo
show_ops
echo
echo "=== STEP 1: a peer lowers rpi3's trust across a tier boundary ==="
echo "    rpi1 calls decrease_guarded on rpi3, dropping it toward STANDARD (>=50)."
echo
echo "\$ docker exec om2m-active sui client call --module trust \\"
echo "    --function decrease_guarded --args <cap> $TRUST_REG $RPI3 <delta> 0x6   (as rpi1)"
echo
sshpass -p user ssh user@10.25.96.200 \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module trust --function decrease_guarded \
     --args $ADMINCAP_RPI1 $TRUST_REG $RPI3 35 0x6 \
     --gas-budget 50000000 2>&1 | grep -iE 'Transaction Digest|Status|MoveAbort|code [0-9]' | head -2 | sed 's/^/    /'"
sleep 3
echo
echo "=== STEP 2: evolve the token against the new (lower) trust ==="
echo
echo "\$ docker exec om2m-active sui client call --module evolution --function evolve \\"
echo "    --args $CAP_TOKEN_RPI3 $TRUST_REG $RPI3 0x6   (signed by rpi3)"
echo
sshpass -p user ssh user@10.25.96.203 \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module evolution --function evolve \
     --args $CAP_TOKEN_RPI3 $TRUST_REG $RPI3 0x6 \
     --gas-budget 50000000 2>&1 | grep -iE 'Transaction Digest|Status|MoveAbort|code [0-9]' | head -2 | sed 's/^/    /'"
sleep 3
echo
echo "=== OPS AFTER (same object id; mask narrowed to match the lower tier) ==="
echo
show_ops
echo
echo "=== RESTORE: raise rpi3 back up and re-evolve (leave system as we found it) ==="
sshpass -p user ssh user@10.25.96.200 \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module trust --function increase_guarded \
     --args $ADMINCAP_RPI1 $TRUST_REG $RPI3 35 0x6 \
     --gas-budget 50000000 >/dev/null 2>&1 && echo '    rpi3 trust restored'"
sshpass -p user ssh user@10.25.96.203 \
  "docker exec om2m-active sui client call \
     --package $PKG_V7 --module evolution --function evolve \
     --args $CAP_TOKEN_RPI3 $TRUST_REG $RPI3 0x6 \
     --gas-budget 50000000 >/dev/null 2>&1 && echo '    token re-evolved to restored tier'"
echo
echo "--------------------------------------------------------------------------------"
echo "WHAT THIS SHOWS: as rpi3's on-chain trust falls across a tier boundary, the"
echo "token's ops mask NARROWS in place (before -> after), on the SAME object id -"
echo "permissions follow measured trust, and the capability evolves without re-issue."
echo "--------------------------------------------------------------------------------"
