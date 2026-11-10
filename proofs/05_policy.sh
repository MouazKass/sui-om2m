#!/usr/bin/env bash
# CONCEPT 5 - POLICY ENFORCEMENT (PO1-PO4, A5).
# Access is gated on-chain by the resource's policy (min trust + ops mask) and
# the token's ops mask; anything outside them is DENIED (fail-closed).
# v8: the request is an ordinary oneM2M DELETE through the DAC path, and
# policy::evaluate reads the trust score itself (A5: no caller-supplied score).
PROOF_ID=05; source "$(dirname "$0")/lib_v8.sh"
banner "CONCEPT 5 - POLICY ENFORCEMENT"
RES=/in-cse/Csui-dac-ae

echo "=== THE POLICY ON-CHAIN (read with dev-inspect, no signature) ==="
echo "    has_policy($RES)    = $(dev_inspect policy has_policy "$POLICY_REG" "'\"$RES\"'")"
echo "    min_trust_for($RES) = $(dev_inspect policy min_trust_for "$POLICY_REG" "'\"$RES\"'")"
echo "    token allowed_ops         = $(obj_json "$CAP_TOKEN_RPI3_DAC" | python -c "import sys,json;print(int(float(json.load(sys.stdin)['content']['allowed_ops'])))") (READ|WRITE; DELETE=4 is not in the mask)"
echo

echo "=== AN ORDINARY oneM2M DELETE OUTSIDE THE GRANTED OPS = DENY (fail-closed) ==="
echo "\$ curl -X DELETE http://127.0.0.1:8282/~/in-cse/in-name/sui-dac-ae -H 'X-M2M-Origin: Csensor-001'   (on rpi3)"
OUT=$(on rpi3 'sleep 6; curl -s -o /dev/null -w "HTTP %{http_code}\n" -X DELETE http://127.0.0.1:8282/~/in-cse/in-name/sui-dac-ae -H "X-M2M-Origin: Csensor-001" -H "Accept: application/json"; sleep 4; docker logs --since 15s om2m-active 2>&1 | grep -E "Sui DAC consult|Sui DENY|Sui GRANT|reason" | tail -3; echo "AE after: $(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8282/~/in-cse/in-name/sui-dac-ae -H "X-M2M-Origin: admin:admin")"')
sed 's/^/    /' <<<"$OUT"
if grep -q "HTTP 403" <<<"$OUT" && grep -q "Sui DENY" <<<"$OUT" && grep -q "AE after: 200" <<<"$OUT"; then
  echo "    [PASS] HTTP 403, Sui DENY, resource untouched"; PROOF_PASS=$((${PROOF_PASS:-0}+1))
  printf '%s,%s,%s,%s,%s,\n' "$(date -u +%FT%TZ)" "$PROOF_ID" "rpi3:DAC DELETE Csensor-001" "deny" "$(grep -oE 'digest=[A-Za-z0-9]+' <<<"$OUT" | tail -1 | cut -d= -f2)" >> "${PROOF_LOG:-/dev/null}"
else
  echo "    [FAIL] expected HTTP 403 + Sui DENY with the AE intact"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1))
fi
echo

echo "=== THE SAME DENIAL, SIGNED DIRECTLY: the chain itself refuses op DELETE ==="
node_ptb rpi3 "--move-call $PKG::identity::verify @$IDENTITY_REG --assign r1 \
  --move-call $PKG::trust::require_min r1 @$TRUST_REG '\"$RES\"' 50 @0x6 --assign r2 \
  --move-call $PKG::cap_token::validate_for_use r2 @$CAP_TOKEN_RPI3_DAC 4u8 @0x6 --assign r3 \
  --move-call $PKG::policy::evaluate r3 @$POLICY_REG @$TRUST_REG @0x6 --assign r4 \
  --move-call $PKG::evaluator::decide_and_log r4 @$AUDIT_TRAIL @0x6"
expect "op DELETE rejected by the token mask (cap_token E_OP_NOT_ALLOWED)" abort 4
echo

echo "=== v8 / A5: THE TRUST GATE HAS NO CALLER-SUPPLIED SCORE ==="
grep -nE "public fun evaluate|trust_score = trust::score_of|E_TRUST_BELOW_MIN\)" move/sources/policy.move | sed 's/^/    /'
echo "    (pre-v8 evaluate took 'requester_trust: u64' from the caller; any PTB could"
echo "     pass 100. It now reads the score from the TrustRegistry for the requester"
echo "     the receipt chain carried forward.)"
echo
hr
echo "WHAT THIS SHOWS: the policy (min_trust, ops mask) is on-chain; a request outside"
echo "the granted operations is DENIED on the real oneM2M path (fail-closed) and by the"
echo "contract itself; the trust gate reads the registry, never a caller's number."
summary
