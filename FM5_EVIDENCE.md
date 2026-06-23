# FM5: Gas Exhaustion Surfaced, Not Silent — Fix and Live Evidence

Status: VERIFIED on the live testnet cluster, 2026-06-23.
Closes invariant FM5.

## The bug (before)
A claim is a gas-paying transaction. An underfunded node failed silently:
SuiObjectFetcher.pickGasCoin throws IOException("no gas coin with balance >= ...")
when no SUI coin meets gasBudget; NativePtbBuilder.claimParent catches it and
returns Result(granted=false, digest=null, error=<that message>). In
FailoverManager.attemptClaim this fell into the generic "Claim rejected on-chain"
branch — indistinguishable from an ordinary on-chain rejection (e.g. a lost race
or a trust-gate abort). An operator could not tell "this node is broke" from
"this node lost a claim".

## The fix
FailoverManager now distinguishes the funding failure:
  - isGasExhaustion(msg): true when the error contains "no gas coin".
  - surfaceGasExhaustion(detail): increments a counter, records timestamp +
    detail, and logs a distinct ERROR ("FM5 GAS EXHAUSTED ...").
  - attemptClaim routes the !granted branch (and the outer catch) through this
    check before the generic-rejection log.
  - Queryable accessors for monitoring/alerting: getGasFailureCount(),
    getLastGasFailureMs(), getLastGasFailureDetail().
A gas failure has digest==null (tx never submitted) and the "no gas coin"
signature, so it is cleanly separable from a submitted-but-aborted claim.

Commit: FM5 on MouazKass/sui-om2m main.

## Test method (matches the invariant's test)
Drain a node's wallet below gasBudget, attempt a claim, assert a distinct
detectable gas-failure signal. rpi2 (0x4be6060a...) ran FM5. Its two coins
(~0.49 + ~0.44 SUI) were transferred to rpi1, leaving a single ~0.011 SUI coin
— below gasBudget=20000000 MIST (0.02 SUI). rpi1 (parent) and rpi3 were stopped
so only rpi2's watchdog fired.

## Result
rpi2's watchdog detected parent silence and attempted to claim. Every attempt
surfaced the distinct signal instead of a generic rejection:
  Parent silence detected (...). Submitting Sui claim.
  FM5 GAS EXHAUSTED - claim could not be funded (need a SUI coin with balance
  >= gasBudget=20000000). This node cannot participate in failover until its
  wallet is refunded. failures=N detail=no gas coin with balance >= 20000000
  for 0x4be6060abaff0b4b6b7229558887f5f054cbe7d9836ba56eff35d848e13dc1f5
The failures counter incremented per attempt (the metric/alert hook). After the
test, rpi2 was refunded (0.48 SUI returned) and the cluster restored.
Evidence: fm5-gas-exhaustion-20260623-*.log (on rpi2)

## Note
Distinct from the orthogonal trust-engine write failure (empty AdminCap), which
is a different on-chain path. FM5 covers only the failover claim's gas funding.
