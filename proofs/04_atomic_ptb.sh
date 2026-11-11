#!/usr/bin/env bash
# CONCEPT 4 - ATOMIC DECISION / NO TOCTOU (ID1-ID4, A6).
# The whole decision is ONE programmable transaction block; in v8 each step
# hands the next a hot-potato receipt (no drop/store/copy), so steps can be
# neither skipped nor re-ordered nor fed forged inputs.
PROOF_ID=04; source "$(dirname "$0")/lib_v8.sh"
banner "CONCEPT 4 - ATOMIC DECISION / NO TOCTOU"

echo "=== Fire an ordinary oneM2M RETRIEVE (real DAC path), then inspect its tx ==="
OUT=$(on rpi3 'sleep 6; curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:8282/~/in-cse/in-name/sui-dac-ae -H "X-M2M-Origin: Csensor-001" -H "Accept: application/json"; sleep 4; docker logs --since 15s om2m-active 2>&1 | grep -E "Sui GRANT" | tail -1')
sed 's/^/    /' <<<"$OUT"
D=$(grep -oE 'digest=[A-Za-z0-9]+' <<<"$OUT" | cut -d= -f2 | tail -1)
echo
echo "\$ sui client tx-block $D --json   (the PTB's command list)"
CHAIN=$(tx_json "$D" | python -c "
import sys,json
d=json.load(sys.stdin)
cmds=d['transaction']['data']['transaction']['transactions']
st=d['effects']['status']['status']
print('    status:', st, '| Move calls inside this ONE transaction:', len(cmds))
names=[]
for i,c in enumerate(cmds):
    m=c.get('MoveCall')
    if not m: continue
    args=', '.join('result %d'%a['Result'] if 'Result' in a else ('input %d'%a['Input'] if 'Input' in a else str(a)) for a in m.get('arguments',[]))
    print('      step %d: %s::%s(%s)'%(i,m['module'],m['function'],args))
    names.append(m['module']+'::'+m['function'])
print('CHAIN='+','.join(names)+';STATUS='+st)
")
grep -v '^CHAIN=' <<<"$CHAIN"
# Step 4 is policy::evaluate (v8/v9) or policy::evaluate_with_device (v10,
# sui.policy.device.binding=true): same receipt in, same receipt out.
want="identity::verify,trust::require_min,cap_token::validate_for_use,policy::evaluate(_with_device)?,evaluator::decide_and_log;STATUS=success"
if grep -Eq "CHAIN=$want" <<<"$CHAIN"; then
  echo "    [PASS] one tx, five steps, each consuming the previous step's receipt"; PROOF_PASS=$((${PROOF_PASS:-0}+1))
  printf '%s,%s,%s,%s,%s,\n' "$(date -u +%FT%TZ)" "$PROOF_ID" "rpi3:DAC GRANT (receipt chain)" success "$D" >> "${PROOF_LOG:-/dev/null}"
else
  echo "    [FAIL] expected chain $want"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1))
fi
echo

echo "=== v8 / A6: SKIPPING A STEP IS A TYPE ERROR (policy step left out) ==="
echo "    rpi3 builds a legitimate chain up to the TokenReceipt, then hands it straight"
echo "    to decide_and_log, which only accepts a PolicyReceipt."
node_ptb rpi3 "--move-call $PKG::identity::verify @$IDENTITY_REG --assign r1 \
  --move-call $PKG::trust::require_min r1 @$TRUST_REG '\"/in-cse/Csui-dac-ae\"' 50 @0x6 --assign r2 \
  --move-call $PKG::cap_token::validate_for_use r2 @$CAP_TOKEN_RPI3_DAC 1u8 @0x6 --assign r3 \
  --move-call $PKG::evaluator::decide_and_log r3 @$AUDIT_TRAIL @0x6"
if [ "$LAST_STATUS" != success ]; then echo "    [PASS] rejected - no GRANT can be logged without passing policy::evaluate"; PROOF_PASS=$((${PROOF_PASS:-0}+1))
else echo "    [FAIL] a step-skipping PTB succeeded"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1)); fi
echo

echo "=== v8 / A6: A RECEIPT CANNOT BE DROPPED (chain started, never finished) ==="
echo "    rpi3 calls identity::verify alone. IdentityReceipt has no 'drop', so a"
echo "    transaction that does not hand it on cannot complete."
node_ptb rpi3 "--move-call $PKG::identity::verify @$IDENTITY_REG"
if [ "$LAST_STATUS" != success ]; then echo "    [PASS] rejected (unused value without drop)"; PROOF_PASS=$((${PROOF_PASS:-0}+1))
else echo "    [FAIL] a dangling receipt was accepted"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1)); fi
echo
hr
echo "WHAT THIS SHOWS: identity, trust, token, policy and the audit write are five"
echo "commands inside ONE transaction, committed atomically - no check-to-use window."
echo "Since v8 the steps are bound by receipts: none can be skipped or left dangling."
summary
