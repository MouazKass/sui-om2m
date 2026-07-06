# Verify these signatures on your laptop before running

The scripts use function names and field names from our build sessions and the
master doc. A few are CONFIRMED (we ran them tonight); a few are INFERRED and you
should confirm against your actual source before demoing to your professor, so
nothing errors live.

## CONFIRMED tonight (ran successfully during the v7 republish)
- trust::increase_guarded  (args: AdminCap, TrustRegistry, node, amount, Clock)  -> script 01, 02
- trust::grant_admin       (args: AdminCap, recipient)                            -> setup
- failover::create_cluster (args: id_vec, parent, gate, timeout, Clock)           -> ref in 06
- cap_token::mint          (args: IssuerCap, recipient, resource, ops, expiry, max_uses)
- policy::set_policy        (args: PolicyAdminCap, PolicyRegistry, resource, min_trust, ops)
- The live GRANT trigger (X-M2M-Operation:5 NOTIFY) -> scripts 03,04,05,08
- selfscore_attack build -> E04001                  -> script 01a

## INFERRED - confirm the exact name/signature in your source before the demo
Check these with:  grep -n "public.*fun <name>" move/sources/<module>.move

- script 02: `trust::get_score`  — you may instead read the score by inspecting
  the TrustRegistry object's dynamic fields (script 02a already does this via the
  object read). If get_score doesn't exist, delete the 02b "BEFORE" line.
- script 06: `failover::claim_parent` — confirm the exact function name (could be
  `claim`, `claim_parent`, `try_claim`). Check: grep -n "fun claim" move/sources/failover.move
  Also confirm its arg list (Cluster, claimant, Clock) — adjust if it takes the
  TrustRegistry too (to check the trust gate on-chain).
- script 06 field names: `epoch`, `current_parent` — confirm against the Cluster
  struct: grep -n "struct Cluster" move/sources/failover.move
- script 07: `evolution` module function + Dynamic Field usage — confirm with
  grep -n "fun " move/sources/evolution.move ; and whether a demote evidence
  script exists (scripts/evolution_demote_evidence.sh — it did in our sessions).
- script 03/07 field name: `allowed_ops` — confirm: grep -n "allowed_ops\|ops" move/sources/cap_token.move
- script 05: evaluator field/error names (min_trust, E_TRUST_TOO_LOW) —
  grep -n "min_trust\|E_" move/sources/evaluator.move

## Quick pre-flight (run once on the laptop)
```bash
cd ~/sui-om2m
for f in trust policy cap_token failover evolution evaluator audit identity; do
  echo "=== $f ==="; grep -nE "public(\(package\))? (entry )?fun " move/sources/$f.move
done
```
Paste that and adjust any script whose function name differs. Most will match;
the failover and evolution ones are the likeliest to need a tweak.
