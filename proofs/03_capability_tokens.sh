#!/usr/bin/env bash
# CONCEPT 3 - CAPABILITY TOKENS (CT1-CT5, A4).
# v8: the token is exercised through the REAL path - an ordinary oneM2M
# RETRIEVE with no special headers, which OM2M routes to the Sui DAS through
# DynamicAuthorizationConsultation (C2). The old NOTIFY shortcut is gone.
PROOF_ID=03; source "$(dirname "$0")/lib_v8.sh"
banner "CONCEPT 3 - CAPABILITY TOKENS"

echo "=== THE TOKEN AS AN ON-CHAIN OBJECT (owner, resource, ops mask) ==="
echo "\$ sui client object \$CAP_TOKEN_RPI3_DAC --json"
obj_json "$CAP_TOKEN_RPI3_DAC" | python -c "
import sys,json
d=json.load(sys.stdin); f=d.get('content',{})
ops=int(f.get('allowed_ops',0)); nm=[n for b,n in ((1,'READ'),(2,'WRITE'),(4,'DELETE'),(8,'ADMIN')) if ops&b]
print('    objectId     :', d.get('objectId'))
print('    type         :', d.get('objType','').split('::',1)[-1])
print('    owner        :', d.get('owner',{}).get('AddressOwner', d.get('owner')))
print('    resource_id  :', f.get('resource_id'))
print('    allowed_ops  :', ops, '=', '+'.join(nm))
print('    uses / max   :', f.get('current_uses'), '/', f.get('max_uses'))
print('    expiry_ms    :', f.get('expiry_ms'))"
echo
echo "=== NON-COPYABLE: the Move type has key+store but NO 'copy' ability ==="
grep -n "public struct CapToken" move/sources/cap_token.move | sed 's/^/    /'
echo

echo "=== AN ORDINARY oneM2M RETRIEVE, AUTHORIZED ON-CHAIN WITH THE TOKEN ==="
echo "\$ curl http://127.0.0.1:8282/~/in-cse/in-name/sui-dac-ae -H 'X-M2M-Origin: Csensor-001'   (on rpi3)"
echo "    (a plain RETRIEVE: no NOTIFY header, no DAS URL. The static ACPs grant"
echo "     Csensor-001 nothing, so OM2M consults the DAC -> the Sui DAS -> one PTB.)"
OUT=$(on rpi3 'sleep 6; curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:8282/~/in-cse/in-name/sui-dac-ae -H "X-M2M-Origin: Csensor-001" -H "Accept: application/json"; sleep 4; docker logs --since 15s om2m-active 2>&1 | grep -E "Sui DAC consult|Sui GRANT|Sui DENY" | tail -2')
sed 's/^/    /' <<<"$OUT"
G=$(grep -oE 'Sui GRANT .*digest=[A-Za-z0-9]+' <<<"$OUT" | grep -oE 'digest=[A-Za-z0-9]+' | cut -d= -f2 | tail -1)
if grep -q "HTTP 200" <<<"$OUT" && [ -n "$G" ]; then
  echo "    [PASS] HTTP 200 and an on-chain GRANT (digest $G)"; PROOF_PASS=$((${PROOF_PASS:-0}+1))
  printf '%s,%s,%s,%s,%s,\n' "$(date -u +%FT%TZ)" "$PROOF_ID" "rpi3:DAC RETRIEVE Csensor-001" "success" "$G" >> "${PROOF_LOG:-/dev/null}"
else
  echo "    [FAIL] expected HTTP 200 + Sui GRANT"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1))
fi
echo

echo "=== v8 / A4: ANOTHER NODE CANNOT SPEND THIS TOKEN ==="
echo "    rpi1 (registered, trusted) builds the full receipt chain but presents"
echo "    rpi3's token. Pre-v8 validate_for_use never checked the signer; now"
echo "    cap_token.move asserts signer == requester == token.owner - and Sui"
echo "    itself refuses to let rpi1 put an object it does not own in a tx."
node_ptb rpi1 "--move-call $PKG::identity::verify @$IDENTITY_REG --assign r1 \
  --move-call $PKG::trust::require_min r1 @$TRUST_REG '\"/in-cse/Csui-dac-ae\"' 50 @0x6 --assign r2 \
  --move-call $PKG::cap_token::validate_for_use r2 @$CAP_TOKEN_RPI3_DAC 1u8 @0x6 --assign r3 \
  --move-call $PKG::policy::evaluate r3 @$POLICY_REG @$TRUST_REG @0x6 --assign r4 \
  --move-call $PKG::evaluator::decide_and_log r4 @$AUDIT_TRAIL @0x6"
if [ "$LAST_STATUS" = error ] && grep -qiE "owned by|not owned|owner|IncorrectUserSignature|ObjectNotOwned" <<<"$LAST_OUT"; then
  echo "    [PASS] rejected before execution: rpi1 cannot use an object owned by rpi3 (nothing on-chain, no gas)"
  PROOF_PASS=$((${PROOF_PASS:-0}+1))
elif [ "$LAST_STATUS" = abort ] && [ "$LAST_CODE" = 5 ]; then
  echo "    [PASS] aborted on-chain with E_NOT_TOKEN_OWNER (5)"; PROOF_PASS=$((${PROOF_PASS:-0}+1))
else
  echo "    [FAIL] expected rejection; got $LAST_STATUS $LAST_CODE"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1))
fi
echo
hr
echo "WHAT THIS SHOWS: the capability is a real on-chain object with a fixed owner,"
echo "resource and ops mask; its Move type is non-copyable; an ordinary oneM2M request"
echo "is granted on-chain with it (digest above); and no other node can spend it."
summary
