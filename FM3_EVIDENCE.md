# FM3 / FM3b: Clean Parent Demotion — Fix and Live Evidence

Status: VERIFIED on the live three-node testnet cluster, 2026-06-22.
Closes the highest-priority gap in the invariants spec (FM3, "clean demotion
of a deposed parent").

## The bug (before)

A node that had been parent could be left holding a stale belief that it was
still parent while the chain had already moved on to a new parent. In
`FailoverManager.watchdogTick`, the self-parent branch only logged
"Self-parent watchdog tripped — our own MQTT is broken" and returned. There
was no path that detected "the chain now names someone else as parent" and
demoted self. Effects observed live:
  - A deposed parent kept publishing parent heartbeats indefinitely
    (ghost parent on the MQTT bus).
  - Two nodes could both believe they were parent (split-brain), each looping
    the self-parent watchdog, neither claiming nor demoting.
  - This blocked organic failover: a stuck-self-parent follower never claimed
    when the real parent died.

## The fix (two parts)

### FM3 — teardown on detected deposition
`startParentDuties()` now also schedules a periodic `parentSelfCheckTask`
(interval `failover.parent.selfcheck.period.ms`, default 15000). While the node
believes it is parent, the task calls `refreshCurrentParent()`. When that read
sees `current_parent != self`, the change-detection block calls a new
`stopParentDuties()` which cancels the heartbeat publisher and the lease anchor
and logs "Parent duties stopped (deposed)". `startParentDuties()` was made
idempotent (cancels any existing tasks before scheduling). The self-check
interval was decoupled from the 10-minute lease-anchor period so detection is
prompt.

### FM3b — watchdog self-correction
The `watchdogTick` self-parent branch no longer assumes our own MQTT is broken.
It first calls `refreshCurrentParent()` (which self-corrects a stale belief and
fires `stopParentDuties()` if we were deposed), and only logs the MQTT-broken
warning if the chain still confirms us as parent. This closes the case where a
node holds a stale-self-parent belief WITHOUT running parent duties (so the
FM3 self-check task was never scheduled).

Commits: FM3 (49fa365, 1657fca), FM3b (7b6d29b) on MouazKass/sui-om2m main.

## Test method

Two-node live test, rpi1 (0xef9c6271...e1d5f9) and rpi2 (0x4be6060a...e13dc1f5),
both running the rebuilt FM3+FM3b plugin, sharing the rpi3 broker
(10.25.96.203:1883). Heartbeats observed directly on topic
om2m/failover/heartbeat/<cluster> with mosquitto_sub. Chain state read from the
cluster object 0x2ca259ed...76a3800.

## Results

### Result 1 — FM3 teardown (deposed-while-running)
rpi1 parent and beating (5s heartbeats). rpi2 claimed parent on-chain
(epoch 29 -> 30, claim digest HY5msmzLnEWjDMqyxsDAs5zMFsARa1UUzqbuk6DY8JW3).
Within ~5s, rpi1's self-check logged:
  Cluster current parent = 0x4be6060abaff...
  Parent duties stopped (deposed): heartbeat + lease anchor cancelled.
rpi1's heartbeats ceased. Teardown confirmed by log and by heartbeat silence.
Evidence: fm3-demotion-20260622-122024.log

### Result 2 — full organic failover (FM3b)
rpi1 parent and beating; rpi2 a clean follower. rpi1 stopped (parent death).
rpi2's watchdog detected silence and claimed organically through its own plugin:
  Parent silence detected (18796 ms). Submitting Sui claim.
  CLAIM ACCEPTED — we are now parent ... digest=G9h2hM2UN5YwoamUUur9mjLFfTUce32A45XjuvzakhSG
Chain moved to rpi2, epoch 32. Only rpi2 (0x4be6...) beating thereafter.
rpi1 was then restarted: it booted parent=rpi2 self=rpi1 (follower), made NO
claim attempts, stayed silent on the heartbeat bus, and the chain held stable
at rpi2/epoch 32 (no re-claim).
Evidence: fm3b-organic-failover-20260622-130158.log

This demonstrates the complete clean lifecycle: parent dies -> follower
organically takes over and holds the role -> old parent rejoins as a stable
follower without a stale self-parent loop and without restart-forced recovery.

## Honest scope / limitations
- Verified on two nodes (rpi1, rpi2). rpi3 still needs config recovery + the
  FM3b JAR to bring the third node under the same code.
- A CLI-driven claim does not start parent duties in the claimer's plugin
  (no refresh-driven "become parent" path); only an organic watchdog claim
  does. This is why Result 1 used a CLI claim to depose (isolating rpi1's
  teardown) and Result 2 used an organic claim (to show the new parent holds).
- The pre-existing OM2M upstream registration loop (5103, IN-CSE registering
  to 127.0.0.1:8080) is cosmetic and unrelated; it is the separate FM4 item.
- Trust-engine on-chain score writes currently fail with an empty AdminCap
  (config omits the admin cap id); this is orthogonal to failover, which uses
  the gated-but-permissionless claim path.

## Result 3 — three-node organic failover with contention (FM3b)

Strongest case: all three nodes on FM3b. rpi2 parent (epoch 32), rpi1 + rpi3
followers. rpi2 stopped (parent death). BOTH followers detected silence and
submitted competing claims on the same parent-death:
  - rpi3 (0x27dacda1...): Parent silence detected (15096 ms) -> CLAIM ACCEPTED,
    digest HYEbwM3JdmRi3tFUShRj2WGxryChjWTNa9GGoAo8ezic
  - rpi1 (0xef9c6271...): Parent silence detected (17635 ms) -> claim rejected
    on-chain, MoveAbort code 3, digest CVvd9DK3wMCCSLA5PUhd9YNoSxdDFZR4Hn2QBCczqvfE

The on-chain claim_parent guard arbitrated atomically: exactly one winner
(rpi3, epoch 33), the competing claim aborted. Only rpi3 beat thereafter; rpi1
settled as follower after its rejection. rpi2 was then restarted: it booted
parent=rpi3 self=rpi2 (follower), made no claim attempts, stayed silent, and
the chain held stable at rpi3/epoch 33.

This demonstrates contention safety on a full cluster: parent dies -> multiple
followers race -> chain admits exactly one new parent -> losing claimant and
revived old parent both converge as stable followers. No split-brain, no dual
parents, no stale-self-parent loop.
