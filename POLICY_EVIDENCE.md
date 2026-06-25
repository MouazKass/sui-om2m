# Policy & Audit Invariants — PO1, PO2, EV2, EV4 — DEMONSTRATED LIVE

Status: VERIFIED on the live testbed (rpi3 + Sui testnet, v5 package), 2026-06-24.
Method: Path A — exercised through the live oneM2M Dynamic Authorization Server
(DAS). Policy state controlled on-chain via the PolicyAdminCap; access decisions
triggered by oneM2M SecurityInfo/DynAuthDasRequest NOTIFYs to the sui-das PoA;
per-condition abort codes confirmed via policy::evaluate dev-inspect.

v5 package:  0xe5500ac65880f0c591315794e50420c47042087c2d8d69b3b3db724e8029c6ac
PolicyRegistry: 0x621e7f65f9e9125ee7d50d08dc4108d30c7e8924353c131f3c2d0da31935a77c
PolicyAdminCap: 0x5014cfabcf799c405b7989c9438d84e55ee5a1941cf95eebc87ba8947ad66883
                (owned by publisher wallet 0xb87fb2af... — PO4 authority separation)
Resource under test: /in-cse/in-name/sui-protected-cnt
Requester: Csensor-001 -> 0x27dacda1... (rpi3), CapToken 0xe474652c..., trust=90

## policy::evaluate signature (confirmed on-chain)
evaluate(&PolicyRegistry, resource: String, op: u8, trust: u64, &Clock)
Note arg order: op THEN trust.

## PO1 — No policy means deny-by-default  [SAFE]
Controlled experiment on the SAME proven path, changing ONLY policy presence:
  1. Policy present  -> NOTIFY -> Sui GRANT, digest 9WeFDQTBUuxPG8MTJEw887qBcb9WMuWWbwSnDs1ZifHM
  2. remove_policy   -> Success, digest EHUMs3rPfbnRFQfqTim6D8rHdwcL4sPXGBMs3urjrvdk
  3. identical NOTIFY -> Sui DENY, "Access PTB aborted"
  4. set_policy restore (50/7) -> Success, digest 8o6YFXL6TVGUqVdfzKaYCgkJZF81qrW7wCsFfHyRvv62
  5. identical NOTIFY -> Sui GRANT again, digest 5RbngT2fYbQkiA1uvRb6z8QA8KrZ6TUGchrWD7Dbgyk8
Same identity, token, trust (90), op — only the policy's existence changed, and the
decision flipped GRANT -> DENY -> GRANT.
Exact abort (policy::evaluate dev-inspect on a policyless resource):
  MoveAbort(..policy.., evaluate, instr 14, code 1) = E_POLICY_MISSING.

## PO2 — All three policy conditions enforced  [SAFE]
Policy baseline: min_trust=50, op_mask=7 (READ|WRITE|DELETE). Each condition tripped
in isolation; exact abort code from policy::evaluate dev-inspect:

  Condition            Test inputs (op, trust)        Abort code            Instr
  -----------------    ----------------------------   -------------------   -----
  Trust below min      op=2 (valid), trust=40 (<50)   3 = E_TRUST_BELOW_MIN  33
  Op not in mask       op=8 (not in mask 7), trust=90 2 = E_OP_DENIED        48
  In blackout window   op=2, trust=90, inside window  4 = E_IN_BLACKOUT      61
  (all satisfied)      op=2, trust=90, no blackout    Success (no abort)     -

Three distinct conditions -> three distinct codes at three distinct instructions,
proving each is independently enforced. The all-satisfied positive control passes.
Blackout set via add_blackout(start=0,end=9999999999999) then cleared via
clear_blackouts (both Success), restoring the working policy.

## EV2 — A denied request never produces a GRANT record  [SAFE]
Structural + observed. The 6-step access PTB reaches evaluator::decide_and_log
(which writes the GRANT AccessLogged, decision=1) ONLY if policy::evaluate passes.
Any policy failure aborts the whole PTB -> full rollback -> NO AccessLogged written.
Observed: every DENY above produced "Access PTB aborted" with no digest and emitted
no AccessLogged event. Denials are recorded out-of-band by evaluator::log_denied
with decision=DECISION_DENIED(0) and token_uses=0, in a separate tx. Therefore a
denied request can never yield a GRANT record.

## EV4 — Every decision emits exactly one AccessLogged event  [LIVE]
Grant path: the live GRANT (digest 9WeFDQTB) emitted EXACTLY ONE AccessLogged:
  decision=1, requested_op=2, requester=0x27dacda1..., resource=sui-protected-cnt,
  token_uses=3, trust_at_check=90, timestamp_ms=1782373830224
  (plus one TokenUsed event — the use-count increment, not a decision record).
Deny path: log_denied emits exactly one AccessLogged with decision=0. Grants ride
the PTB (decide_and_log -> log); denials go through log_denied -> log; each emits one.

## Integration note
These invariants are properties of the on-chain policy/evaluator/audit modules.
They are exercised in production through the oneM2M TS-0003 Dynamic Authorization
Server: a SecurityInfo NOTIFY to the sui-das PoA triggers the 6-step PTB whose
step 4 is policy::evaluate. The live GRANT/DENY demonstrations above ran through
that exact DAS path on the v5 package.
