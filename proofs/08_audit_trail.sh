#!/usr/bin/env bash
# CONCEPT 8 - AUDIT TRAIL (SY1-SY5, A7).
# Every GRANT appends a record (and emits AccessLogged) on an on-chain ring
# buffer; no edit/delete path exists. v8 / A7: nobody can write a record
# directly any more - audit::log and evaluator::log_denied are
# public(package), reachable only through the receipt chain (GRANT) or with
# the AuditAdminCap (log_denied_authorized).
PROOF_ID=08; source "$(dirname "$0")/lib_v8.sh"
banner "CONCEPT 8 - AUDIT TRAIL"

count() { obj_json "$AUDIT_TRAIL" | python -c "import sys,json; print(json.load(sys.stdin)['content']['next_slot'])"; }
echo "=== THE AUDIT TRAIL OBJECT ON-CHAIN ==="
obj_json "$AUDIT_TRAIL" | python -c "
import sys,json; d=json.load(sys.stdin); f=d['content']
print('    trail id :', d['objectId']); print('    owner    :', d['owner'])
print('    ring_size:', f.get('ring_size'), '| records written (next_slot):', f.get('next_slot'))"
C0=$(count); echo

echo "=== AN ORDINARY oneM2M RETRIEVE APPENDS A RECORD AND EMITS AN EVENT ==="
OUT=$(on rpi3 'sleep 6; curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:8282/~/in-cse/in-name/sui-dac-ae -H "X-M2M-Origin: Csensor-001" -H "Accept: application/json"; sleep 4; docker logs --since 15s om2m-active 2>&1 | grep -E "Sui GRANT" | tail -1')
sed 's/^/    /' <<<"$OUT"
D=$(grep -oE 'digest=[A-Za-z0-9]+' <<<"$OUT" | cut -d= -f2 | tail -1)
tx_json "$D" | python -c "
import sys,json
d=json.load(sys.stdin)
for e in d.get('events',[]):
    print('    event:', e.get('type','').split('::',1)[-1]); print('      ', json.dumps(e.get('parsedJson',{}))[:260])"
sleep 2; C1=$(count); echo "    records written: $C0 -> $C1"
if [ -n "$D" ] && [ "$C1" -gt "$C0" ]; then echo "    [PASS] the GRANT appended to the trail"; PROOF_PASS=$((${PROOF_PASS:-0}+1))
  printf '%s,%s,%s,%s,%s,\n' "$(date -u +%FT%TZ)" "$PROOF_ID" "rpi3:DAC GRANT (audit append)" success "$D" >> "${PROOF_LOG:-/dev/null}"
else echo "    [FAIL] no new record"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1)); fi
echo

echo "=== v8 / A7: A NODE CANNOT WRITE AN AUDIT RECORD DIRECTLY ==="
echo "    rpi1 tries to append a forged GRANT for itself via audit::log."
node_ptb rpi1 "--move-call $PKG::audit::log @$AUDIT_TRAIL @$RPI1 '\"/in-cse/Csui-dac-ae\"' 1u8 1u8 100 0 @0x6"
[ "$LAST_STATUS" != success ] && { echo "    [PASS] rejected"; PROOF_PASS=$((${PROOF_PASS:-0}+1)); } || { echo "    [FAIL] forged record accepted"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1)); }
echo "    rpi1 tries to write a forged DENY through evaluator::log_denied."
node_ptb rpi1 "--move-call $PKG::evaluator::log_denied @$AUDIT_TRAIL @$RPI3 '\"/in-cse/Csui-dac-ae\"' 1u8 0 @0x6"
[ "$LAST_STATUS" != success ] && { echo "    [PASS] rejected"; PROOF_PASS=$((${PROOF_PASS:-0}+1)); } || { echo "    [FAIL] forged denial accepted"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1)); }
C2=$(count); echo "    records written: $C1 -> $C2 (unchanged)"
[ "$C2" = "$C1" ] || echo "    (note: a live GRANT may have landed meanwhile)"
echo
echo "=== IMMUTABILITY IS STRUCTURAL (audit module surface) ==="
grep -nE "public(\(package\))? fun " move/sources/audit.move | sed 's/^/    /'
echo "    (no edit or delete of a past record; log is package-only)"
echo
hr
echo "WHAT THIS SHOWS: the trail is an on-chain object; each decision appends a record"
echo "and emits AccessLogged; no external party can write, edit or delete records."
summary
