# AdminCap Delegation + Live Trust Scoring — Fix and Evidence

Status: VERIFIED on the live testnet cluster, 2026-06-23.

## The bug (before)
The trust module's score-writing functions (increase/decrease/*_guarded,
add_node) all require an AdminCap. Each node's TrustScoringEngine submits peer
trust deltas via NativePtbBuilder.submitTrustDelta(... adminCapId), reading the
cap id from config key trust.admin.cap.id. That key was empty on all nodes
(omitted during cluster recovery — the sui.properties sample had no such key),
so every on-chain trust write failed:
  [trust] <peer> increase by N failed: ... AccountAddressParseError
Trust scores on-chain were effectively frozen: the engine observed peers but
could never persist a score. This undercut the "dynamic on-chain trust" claim.

## Trust model (design, confirmed in code)
Scoring is a PERMISSIONED, DELEGATED, PEER-driven model:
  - A genesis authority (the package publisher, holder of the original AdminCap
    0xd858c23d...) mints a per-node AdminCap via trust::grant_admin and transfers
    it to each node. Genesis-only involvement.
  - Each node then scores its PEERS from local gossip observation. It never
    scores itself: enforced in software (TrustScoringEngine skips self in the
    target loop) AND on-chain (the *_guarded variants take TxContext and abort a
    self-score). Reads (score_of/require_min) are open.
  - Steady-state trust is fully peer-driven; the publisher is not in the loop.
Engine writes ONLY on an EMA tier crossing (TE3): tierOf(ema) != tierOf(lastOnChain),
alpha=0.3, 60s window. Sub-tier drift never writes.

## The fix
1. grant_admin (from publisher) minted an AdminCap to each node:
     rpi1 0xef9c... -> cap 0x3f9f14b4...
     rpi2 0x4be6... -> cap 0x4d1dc0d7...
     rpi3 0x27dac... -> cap 0x024310d9...
2. Added trust.admin.cap.id=<cap> to each node's sui.properties (+ durable copy
   in ~/sui-runtime-config), restarted engines (OSGi cache cleared).
Engine startup now shows adminCap=<cap> populated; the AccountAddressParseError
spam stopped cluster-wide (0 failures post-fix).

## Evidence
1. Contract/cap works (direct CLI write): rpi1, using its cap, called
   increase_guarded on peer rpi2 -> rpi2 score 73 -> 75 on-chain
   (digest 7xRrPNnGaBmz38yvY9k2EMAoHYKWY5iin1N9aS9ddDYV).
2. Autonomous engine works (organic tier-crossing writes, peers scoring peers):
     rpi2's engine: rpi1 crossed tier 4->3 (87); rpi3 crossed tier 2->3 (80)
     rpi3's engine: rpi2 crossed tier 2->3 (85); rpi1 crossed tier 3->4 (91)
   all "submitted on-chain". Scores climbed as well-behaving peers earned trust
   (rpi3 reached 100, rpi1 96, rpi2 85). No node ever scored itself.
Evidence log: trust-organic-20260623-*.log (on rpi2).

## Note
Each node currently owns two AdminCaps (an extra from an earlier grant); only the
configured one is used. Harmless; could be cleaned up. The orthogonal FM4 5103
loop and the (now-fixed) trust write are unrelated paths.
