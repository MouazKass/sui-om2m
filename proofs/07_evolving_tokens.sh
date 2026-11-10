#!/usr/bin/env bash
# CONCEPT 7 - SELF-EVOLVING TOKENS (EVO1-EVO7, A9).
# A token's ops mask follows its owner's on-chain trust, in place (same object
# id, dynamic fields). v8 changes the demonstration in two ways:
#   * A12 caps a trust write at 15 points, so the demotion crosses ONE tier
#     boundary (CUSTODIAN >=90 -> TRUSTED >=75), not the old -35 jump;
#   * A9: evolve() reads the SIGNER's own score - there is no node address
#     argument left to point at a more trusted node.
# It uses a dedicated proof token (resource /proof/evolution, no policy, so it
# authorizes nothing), never the production tokens. Self-restoring for rpi3.
PROOF_ID=07; source "$(dirname "$0")/lib_v8.sh"
banner "CONCEPT 7 - SELF-EVOLVING TOKENS"
echo "  Tier map: >=90 CUSTODIAN(15) | >=75 TRUSTED(7) | >=50 STANDARD(3) | >=25 BASIC(1) | <25 PROBATION(1)"
echo

ops_of() { obj_json "$1" | python -c "
import sys,json; f=json.load(sys.stdin)['content']; o=int(float(f['allowed_ops']))
print(o, '=', '+'.join(n for b,n in ((1,'READ'),(2,'WRITE'),(4,'DELETE'),(8,'ADMIN')) if o&b) or '(none)')"; }
step_evolve() { node_call rpi3 evolution evolve "$PT" "$TRUST_REG" 0x6; expect "$1" success; echo "    ops now: $(ops_of "$PT")   (rpi3 score $(score "$RPI3"))"; }

PT=${PROOF_TOKEN:-$(grep -s '^PROOF_TOKEN=' evidence/v8-measurements/proof_token.env | cut -d= -f2)}
if [ -z "$PT" ]; then
  echo "=== SETUP: mint a proof token to rpi3 (publisher's IssuerCap) and bootstrap its tier ==="
  EXP=$(( ($(date +%s) + 30*86400) * 1000 ))
  pub_call cap_token mint "$ISSUER_CAP" "$RPI3" "'\"/proof/evolution\"'" 1 "$EXP" 100
  expect "proof token minted" success
  PT=$(python -c "
import sys,json; t=sys.stdin.read(); d=json.loads(t[t.find('{'):])
print(next(c['objectId'] for c in d['objectChanges'] if c.get('type')=='created' and c.get('objectType','').endswith('::cap_token::CapToken')))" <<<"$LAST_OUT")
  echo "PROOF_TOKEN=$PT" > evidence/v8-measurements/proof_token.env
  node_call rpi3 evolution bootstrap "$PT" 0x6
  expect "tier fields bootstrapped (dynamic fields on the same object)" success
fi
echo "    proof token: $PT"
echo

S0=$(score "$RPI3"); echo "=== START: rpi3 score $S0 ==="
[ "$S0" -ge 90 ] || { echo "    rpi3 is below 90; this run needs it in CUSTODIAN. Aborting."; exit 1; }
step_evolve "evolve at the starting score"
OPS0=$(ops_of "$PT" | cut -d' ' -f1)
echo

echo "=== STEP 1: a peer lowers rpi3's trust across the 90 boundary (A12: at most 15) ==="
DROP=$(( S0 - 89 )); [ $DROP -gt 15 ] && DROP=15
node_call rpi1 trust decrease_guarded "$ADMINCAP_RPI1" "$TRUST_REG" "$RPI3" "$DROP" 0x6
[ "$LAST_STATUS:$LAST_CODE" = "abort:7" ] && { echo "    (rate-limited by a live engine write; retrying after 62 s)"; sleep 62; node_call rpi1 trust decrease_guarded "$ADMINCAP_RPI1" "$TRUST_REG" "$RPI3" "$DROP" 0x6; }
expect "rpi1 lowers rpi3 by $DROP" success; T1=$(date +%s)
echo
echo "=== STEP 2: rpi3 evolves its token - the mask NARROWS in place ==="
step_evolve "evolve after the demotion"
OPS1=$(ops_of "$PT" | cut -d' ' -f1)
if [ "$OPS0" = 15 ] && [ "$OPS1" = 7 ]; then echo "    [PASS] 15 -> 7 on the same object id (ADMIN dropped)"; PROOF_PASS=$((${PROOF_PASS:-0}+1))
else echo "    [FAIL] expected 15 -> 7, got $OPS0 -> $OPS1"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1)); fi
echo

echo "=== v8 / A9: evolve takes no node address - it scores the signer ==="
grep -nE "public fun evolve|let node_addr = tx_context::sender|E_NOT_TOKEN_OWNER\)" move/sources/evolution.move | sed 's/^/    /'
echo

echo "=== RESTORE: raise rpi3 back and re-evolve (leave the system as found) ==="
wait_rate_limit "$T1"
node_call rpi1 trust increase_guarded "$ADMINCAP_RPI1" "$TRUST_REG" "$RPI3" "$DROP" 0x6
[ "$LAST_STATUS:$LAST_CODE" = "abort:7" ] && { sleep 62; node_call rpi1 trust increase_guarded "$ADMINCAP_RPI1" "$TRUST_REG" "$RPI3" "$DROP" 0x6; }
expect "rpi1 restores rpi3 by $DROP" success
step_evolve "re-evolve after the restore"
OPS2=$(ops_of "$PT" | cut -d' ' -f1)
[ "$OPS2" = "$OPS0" ] && { echo "    [PASS] mask widened back to $OPS2"; PROOF_PASS=$((${PROOF_PASS:-0}+1)); } \
                      || { echo "    [FAIL] mask $OPS2, expected $OPS0"; PROOF_FAIL=$((${PROOF_FAIL:-0}+1)); }
echo
hr
echo "WHAT THIS SHOWS: as rpi3's on-chain trust crosses a tier boundary the token's ops"
echo "mask narrows (and later widens) in place, on the same object id; the score used"
echo "is always the signer's own (A9), and each step is bounded by A12."
summary
