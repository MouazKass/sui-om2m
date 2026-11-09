# Security Batch A1-A12 / B1-B12 / C1-C6 — Code Verified, Deployment Pending

Status: SOURCE-VERIFIED on branch `security-fixes-v8`, 2026-11-09.
Scope: 8 Move modules (fresh v8 publish, `Move.toml` version 0.8.0), the
Java DAS/trust plugin, and the proof/bench/config scripts.
NOT deployed: no `sui client publish` and no wallet transaction was performed
by this batch, so nothing here carries a testnet digest. Every claim below is
either a compiler/unit-test result reproduced in this environment or a
source-level reading, and is labelled as such.

Reproduced in this environment (both commands from `move/`):

    sui move build     # sui 1.83.1 — exit 0, 0 errors, 6 warnings
    sui move test      # Test result: OK. Total tests: 66; passed: 66; failed: 0

The 6 warnings are all `WC04037 deprecated usage` on `sui::dynamic_field::exists_`
(renamed to `exists`) in the TR7 block of trust.move (sites include lines 398,
429, 465, 481). They pre-date this batch and are not introduced by it.

Java: 24 of the 26 plugin main sources compile clean under JDK 21
(`javac` exit 0). The 4 JUnit classes compile and run: **OK (33 tests)**.
`das/SuiDasService.java` and `SuiPluginActivator.java` do not compile here —
see "Not verified in this environment".

---

# Part A — Move contracts

## A1 — `trust::add_node` accepted an AdminCap it never checked

**Problem.** `add_node` took the cap as `_admin` and never read it. TR7 gave the
registry a per-cap validity set, but `add_node` was outside it: a revoked cap
could still create trust entries, i.e. could still mint the state that every
later access decision reads.

**Before** (HEAD, trust.move:88):

    public fun add_node(_admin: &AdminCap, registry: &mut TrustRegistry,
                        node_addr: address, initial_score: u64, clock: &Clock)

**After** (trust.move:130): the parameter is named `admin` and
`assert_cap_valid(admin, registry)` runs before anything is written.

**Verification.** `tests/admin_cap_validity_tests.move`:
`a1_revoked_cap_cannot_add_node` — `#[expected_failure(abort_code = 5,
location = om2m_access::trust)]`, i.e. `E_CAP_REVOKED`. Positive control
`a1_valid_cap_can_add_node` passes.

## A2 — a revoked admin could re-arm itself via `bootstrap_valid_caps`

**Problem.** `bootstrap_valid_caps` seeds the validity set. It was reachable by
any AdminCap holder, so a cap that had just been `revoke_admin`'d could call it
and re-insert its own id.

**After.** The granting/bootstrapping cap is itself validated first.

**Verification.** `a2_revoked_cap_cannot_rebootstrap_itself` — abort code 5
(`trust::E_CAP_REVOKED`). Positive control `a2_valid_cap_can_bootstrap` passes.

## A8 — two mint paths, only one of them revocable

**Problem.** There were two ways to obtain an AdminCap and they did not agree.
`grant_admin` minted a bare `AdminCap { id: object::new(ctx) }` and never
touched the validity set — a cap TR7 could never revoke, because revocation
works by removing an id from a set the cap was never in. `grant_admin_registered`
did register the new id, but took the granting cap as `_admin` and never
validated it, so a revoked admin could mint fresh, valid-looking caps
indefinitely.

**Before** (HEAD, trust.move:227 and :239):

    public entry fun grant_admin(_admin: &AdminCap, recipient: address,
                                 ctx: &mut TxContext)
        { let cap = AdminCap { id: object::new(ctx) };
          transfer::public_transfer(cap, recipient); }

    public entry fun grant_admin_registered(_admin: &AdminCap,
            registry: &mut TrustRegistry, recipient: address, ctx: &mut TxContext)
        { /* registers cid, but never checks `_admin` */ }

**After.** One private authority, `mint_and_register`, which validates the
GRANTING cap and then registers the minted id:

    fun mint_and_register(admin: &AdminCap, registry: &mut TrustRegistry,
                          recipient: address, ctx: &mut TxContext) {
        assert_cap_valid(admin, registry);
        let cap = AdminCap { id: object::new(ctx) };
        ...insert object::id(&cap) into the validity set...
    }

Both `grant_admin` (trust.move:335) and `grant_admin_registered`
(trust.move:346) are now one-line delegations to it. `grant_admin` therefore
gained a `&mut TrustRegistry` parameter — a breaking signature change, which is
only admissible because v8 is a fresh publish and not a compatible upgrade
(contrast TR7_EVIDENCE.md, where keeping `grant_admin`'s signature intact was
precisely why the second function had to exist at all).

**Verification.** Five tests in `tests/admin_cap_validity_tests.move`:
- `a8_revoked_cap_cannot_grant_admin_registered` — abort 5
- `a8_revoked_cap_cannot_grant_admin_to_itself` — abort 5
- `a8_grant_admin_registers_new_cap_in_validity_set` — passes (the legacy path
  now produces a tracked cap)
- `a8_cap_minted_by_grant_admin_is_revocable` — abort 5 after revocation, which
  is the property the old `grant_admin` structurally could not have
- `a8_valid_cap_can_grant_and_grantee_can_write` — positive control

### A1/A2/A8 flagged: without the `init` change, all three checks were inert

This is the part of the batch most easily got wrong, so it is called out
separately.

`assert_cap_valid` is gated on a `tr7_bootstrapped` dynamic-field marker. That
gate exists for a good reason: TR7 shipped as a *compatible upgrade* onto a
running cluster, and caps minted by the previous version had to keep working
until an operator ran `bootstrap_valid_caps`. So the semantics are FAIL-OPEN
before the marker is set and FAIL-CLOSED after.

Adding `assert_cap_valid` to `add_node`, to the bootstrap path and to the mint
path therefore changes nothing on a freshly published package: the marker is
absent, so every one of the new asserts is a silent no-op, and stays one until
somebody remembers to run a manual bootstrap transaction. A1/A2/A8 would have
read as fixed in the diff and been unenforced on chain.

`trust::init` now closes this (trust.move:104):

    let genesis_id = object::id(&cap);
    let set = valid_caps_mut(&mut registry);
    vec_set::insert(set, genesis_id);
    df::add(&mut registry.id, BOOTSTRAPPED_KEY, true);

The genesis cap is registered and enforcement is armed in the publish
transaction itself. On a v8 package the fail-open window is not merely unused —
it is not observable, because no transaction can run between `init` and the
marker being set.

**Verification.** Indirect but conclusive within the test suite: every A1/A2/A8
abort-5 test above sets up its world through `trust::init_for_testing` and
performs *no* bootstrap call, yet still observes `E_CAP_REVOKED`. If `init` did
not arm the marker, those tests would pass the assert and fail.

## A3 — `identity::verify` trusted a caller-supplied address

**Problem.** The function asserted that a *claimed* address was in the registry.
It never compared that address to the transaction signer, so any sender could
assert the registration of any registered node and have the rest of the chain
treat them as that node.

**Before** (HEAD, identity.move:114):

    public fun verify(registry: &Registry, claimed: address) {
        assert!(table::contains(&registry.nodes, claimed), E_NOT_REGISTERED);
    }

**After** (identity.move:135): the parameter is **deleted**, not validated —
the requester is derived, so there is no forgeable input left:

    public fun verify(registry: &Registry, ctx: &TxContext): IdentityReceipt {
        let requester = tx_context::sender(ctx);
        assert!(table::contains(&registry.nodes, requester), E_NOT_REGISTERED);
        IdentityReceipt { requester }
    }

**Verification.** `tests/receipt_chain_tests.move`:
`a3_verify_rejects_unregistered_sender` — `#[expected_failure(abort_code = 1,
location = om2m_access::identity)]` (`E_NOT_REGISTERED`);
`a3_receipt_always_carries_the_actual_signer` and
`a3_verify_accepts_registered_sender` pass.

## A4 — token use was not bound to the token's owner

**Problem.** `cap_token::validate_for_use` checked resource, op mask, expiry and
use count, but not who was spending the token. A transferred (or stolen) CapToken
could be spent by its new holder against the original owner's authorisation, and
the resource id was a caller-supplied `&String`.

**Before** (HEAD, cap_token.move:146):

    public fun validate_for_use(token: &mut CapToken, resource_id: &String,
                                requested_op: u8, clock: &Clock)

**After** (cap_token.move:177): consumes the `TrustReceipt` by value, recovers
the authenticated requester from it, and requires signer == requester == owner:

    public fun validate_for_use(trust_receipt: TrustReceipt, token: &mut CapToken,
            requested_op: u8, clock: &Clock, ctx: &TxContext): TokenReceipt {
        let (requester, resource_id) = trust::consume_trust_receipt(trust_receipt);
        assert!(tx_context::sender(ctx) == requester, E_NOT_TOKEN_OWNER);
        assert!(token.owner == requester, E_NOT_TOKEN_OWNER);

`E_NOT_TOKEN_OWNER` is code 5. Note the resource id is no longer an argument at
all: it arrives inside the receipt.

**Verification.** `a4_non_owner_cannot_use_a_transferred_token` — abort 5
(`cap_token::E_NOT_TOKEN_OWNER`); `a4_owner_can_use_its_own_token` passes.

## A5 — `policy::evaluate` was handed the trust score it was supposed to test

**Problem.** The policy check's central condition is "requester trust >=
min_trust", and the trust figure was a `u64` the caller passed in. A client could
simply submit the number that satisfied the policy.

**Before** (HEAD, policy.move:161):

    public fun evaluate(registry: &PolicyRegistry, resource_id: &String,
            requested_op: u8, requester_trust: u64, clock: &Clock): u64

**After** (policy.move:185): the parameter is deleted and the score is read
in-module from the `TrustRegistry`:

    public fun evaluate(token_receipt: TokenReceipt, registry: &PolicyRegistry,
            trust_reg: &TrustRegistry, clock: &Clock): PolicyReceipt

**Verification.** `tests/receipt_chain_tests.move`:
- `a5_forged_low_min_required_cannot_fake_a_trust_score` — abort 3
  (`policy::E_TRUST_BELOW_MIN`). The requester clears step 2 by asking for a
  trivially low `min_required`, and is still denied at step 4 because step 4 no
  longer believes the caller about the score.
- `a5_policy_receipt_reports_the_registry_score` and
  `a5_evaluated_score_tracks_registry_changes` pass.

## A6 — the six PTB steps were independent calls with no enforced order

**Problem.** `identity::verify`, `trust::require_min`, `cap_token::validate_for_use`,
`policy::evaluate` and `evaluator::decide_and_log` were five public functions
with no data dependency on one another. Atomicity came from the PTB, but nothing
stopped a client from submitting a PTB containing only step 6, or from passing a
different requester/resource/op to each step.

**Design.** A Move "hot potato" receipt chain. Five structs with **no**
`drop`, `store`, `copy` or `key` ability, each constructible only inside its
own module and consumable only by the next link:

    identity::IdentityReceipt { requester }                          (identity.move:48)
      -> trust::TrustReceipt   { requester, resource_id }            (trust.move:80)
      -> cap_token::TokenReceipt { requester, resource_id, requested_op,
                                   token_id, token_uses }           (cap_token.move:106)
      -> policy::PolicyReceipt { requester, resource_id, requested_op,
                                 trust_score, min_trust, token_uses } (policy.move:66)
      -> evaluator::decide_and_log consumes it

Because the structs lack `drop`, a receipt that is produced must be consumed:
a PTB that calls step 1 and stops does not type-check. Because they lack
`store`/`key`, they cannot be parked in an object across transactions. Because
construction is module-private, no caller can fabricate one. The requester,
resource and op are carried *inside* the receipts rather than re-supplied per
step, so they cannot diverge between steps.

`trust::require_min` (trust.move:229) correspondingly lost its `node_addr`
parameter — the node whose score is read is the one `identity::verify`
authenticated.

**Verification.** `tests/receipt_chain_tests.move`:
- `a6_full_chain_in_order_grants_and_logs` — the full ordered chain yields a
  decision and writes the audit record
- `a6_receipt_binding_survives_every_hop` — requester/resource/op are identical
  at each link
- `a6_low_trust_requester_is_denied_by_the_chain` — abort 3
  (`policy::E_TRUST_BELOW_MIN`)
- `a6_resource_cannot_be_retargeted_mid_chain` — abort 3
  (`cap_token::E_RESOURCE_MISMATCH`)

**Limit of the claim.** The "cannot skip or reorder" half of A6 is a
*compile-time* property and is deliberately not asserted by a test. Move has no
`#[expected_compile_failure]`, and since the receipts are undroppable and
module-constructed, the malformed call is *unwritable* rather than rejected at
runtime — there is no abort to observe. What the tests above do prove is that
the chain yields a decision only when run in full, correct order, and that the
requester/resource/op binding survives every hop. No test here should be read as
proving the reorder case.

## A7 — the canonical audit trail was writable by anyone

**Problem.** `audit::log` was `public fun`. Any external transaction could append
a fully attacker-controlled record — including `decision = GRANTED` for a request
that never happened — to the shared `AuditTrail` and emit a matching
`AccessLogged` event. The audit trail is the artefact the evaluation chapter
cites, so this is the integrity of the evidence, not only of the state.

**After.** `audit::log`, `evaluator::log_denied` and
`evaluator::decide_and_log` are `public(package)` (audit.move:109,
evaluator.move:97, evaluator.move:62). The only remaining ways to write a record
are:
- `evaluator::decide_and_log`, which requires an unforgeable `PolicyReceipt`,
  which can only exist if steps 1-4 all passed; and
- `evaluator::log_denied_authorized` (evaluator.move:124), which requires the
  `AuditAdminCap`.

**Verification.** `a7_log_denied_authorized_writes_record` passes — the
capability-gated deny path still works.

**Limit of the claim — A7 is not provable by in-package Move tests.** A
`#[test_only]` module compiles *into* the package, so `public(package)` is
satisfied for it and the unauthorized call simply succeeds; there is no abort to
expect. An unauthorized call from a genuinely external package is a **link
error in the calling package**, not a Move abort, so it cannot be expressed as
`#[expected_failure]` either. The guarantee rests on the visibility modifier
plus the unforgeable receipt types, verified by reading the declarations. Do not
cite a test as proof of A7.

## A9 — `evolution::evolve` read a caller-named node's score

**Problem.** `evolve` re-tiers a `CapToken`'s op mask from a trust score, and
took the address whose score to read as an argument. A node could pass a
high-scoring peer's address and have its own token upgraded on that peer's
reputation.

**Before** (HEAD, evolution.move:114):

    public fun evolve(token: &mut CapToken, trust_reg: &TrustRegistry,
                      node_addr: address, clock: &Clock)

**After** (evolution.move:100): parameter deleted, `ctx` added, address derived:

    public fun evolve(token: &mut CapToken, trust_reg: &TrustRegistry,
                      clock: &Clock, ctx: &TxContext) {
        let node_addr = tx_context::sender(ctx);

**Verification.** `tests/evolution_lifecycle_tests.move`:
- `a9_evolve_cannot_borrow_another_nodes_score` — passes
- `a9_non_owner_cannot_evolve_a_transferred_token` — abort 3
  (`evolution::E_NOT_TOKEN_OWNER`)
- `a9_owner_evolves_with_its_own_score` — positive control

The nine pre-existing tier tests (`evo_tier_probation_score_10` through
`evo_tier_custodian_score_100`) and `evo_promote_then_demote_strips_ops` still
pass, so the tier mapping is unchanged by the signature change.

## A10 — unbounded failover lease could permanently block takeover

**Problem.** `lease_expires_ms` is what `claim_parent` tests to decide whether
the incumbent parent's lease has lapsed. With an unbounded lease a parent could
set `u64::MAX` and no takeover would ever be possible again — a permanent denial
of the failover property, written by a single legitimate call.

**After.** `MAX_LEASE_MS = 3_600_000` (failover.move:59) and
`E_LEASE_TOO_LONG = 7` (failover.move:44).

### A10 flagged: the obvious fix was only half the attack surface

Fixing `renew_lease` alone leaves the vulnerability fully reachable.
`create_cluster` writes the *same* `lease_expires_ms` field from its own
`initial_lease_ms` argument and is permissionless — it mints the
`ClusterAdminCap` rather than requiring one. So the original attack (create a
cluster whose lease never expires, so `claim_parent` can never succeed) survives
a `renew_lease`-only patch untouched. The bound is asserted in **both** writers:

    failover.move:132   assert!(initial_lease_ms <= MAX_LEASE_MS, E_LEASE_TOO_LONG);  // create_cluster
    failover.move:179   assert!(new_lease_ms     <= MAX_LEASE_MS, E_LEASE_TOO_LONG);  // renew_lease

The `renew_lease` assert additionally makes the subsequent `now + new_lease_ms`
addition non-overflowing.

**Verification.** `tests/failover_lease_tests.move`, nine tests, with three
dedicated to the `create_cluster` half:
- `a10_create_cluster_rejects_one_ms_over_max` — abort 7
- `a10_create_cluster_rejects_u64_max_forever_lease` — abort 7
- `a10_create_cluster_accepts_exact_max` — passes (boundary is inclusive)
- `a10_renew_lease_rejects_one_ms_over_max` — abort 7
- `a10_renew_lease_rejects_u64_max_forever_lease` — abort 7
- `a10_renew_lease_accepts_typical_and_exact_max` — passes
- `a10_non_parent_cannot_renew_lease` — abort 4 (`E_NOT_PARENT_ROLE`)
- `a10_takeover_remains_reachable_after_max_renewal` — passes; this is the
  property the bound exists for
- `a10_takeover_refused_while_lease_valid` — abort 3 (`E_LEASE_STILL_VALID`)

## A11 — `SubCapability` removed as dead authority-bearing state

**Problem.** `evolution.move` defined `SubCapability` (HEAD line 65), the
`SubCapabilityAttached` event (line 80) and `attach_sub_capability` (line 177),
a Transfer-to-Object demonstration. Nothing anywhere read a `SubCapability`'s
fields in an access decision — the only writer was the demo path. It was
unreferenced state that nonetheless looked like it conferred authority.

**After.** All three deleted outright (see the explanatory comments retained at
evolution.move:15 and :162). `grep -rn SubCapability move/sources/` returns only
those comments. Deleting a public struct and a public function is a breaking
change, admissible only because v8 is a fresh publish.

A stale `sources/evolution.move.bak` holding the pre-A9/A11 module was also
removed (226 lines, shown as `D` in `git status`); left in place it would have
been a second, contradictory copy of the module next to the real one.

**Verification.** `sui move build` exit 0 proves nothing in the package
referenced the removed items; the 20 tests in
`tests/evolution_lifecycle_tests.move` pass against the reduced module.

## A12 — score writes were unbounded in magnitude and rate

**Problem.** `increase`/`decrease` applied an arbitrary `delta` with no
rate limit. A single AdminCap holder (or a compromised node agent in a tight
loop) could move any node's score the full 0-100 range in one transaction, or
grind it with a burst of small writes — which also means the trust score that
gates policy and failover could be driven anywhere faster than any human or
peer could react.

**After.** `MAX_DELTA = 15` and `MIN_INTERVAL_MS = 60_000` (trust.move:56-57),
with `E_DELTA_TOO_LARGE = 6` and `E_RATE_LIMITED = 7`, enforced by one guard on
the write path (trust.move:154):

    fun assert_write_allowed(entry: &TrustEntry, delta: u64, now_ms: u64) {
        assert!(delta <= MAX_DELTA, E_DELTA_TOO_LARGE);
        assert!(now_ms >= entry.last_update_ms + MIN_INTERVAL_MS, E_RATE_LIMITED);
    }

The rate limit reuses the existing `TrustEntry.last_update_ms` field, so it adds
no state.

**Verification.** `tests/trust_revocation_tests.move`:
- `a12_delta_above_max_is_rejected` — abort 6
- `a12_write_too_soon_is_rejected` — abort 7
- `a12_second_write_in_same_instant_is_rejected` — abort 7
- `a12_writes_within_limits_are_accepted` — passes

The pre-existing `tr7_revoked_cap_cannot_score` (abort 5),
`tr7_valid_cap_can_score`, `tr7_burn_removes_cap` and `self_scoring_is_rejected`
(abort 4, `E_SELF_SCORING`) still pass.

## Test-only additions (no effect on published bytecode)

`Registry` (identity), `AuditTrail` (audit), `PolicyRegistry` (policy),
`TrustRegistry` (trust) and the cap_token registry are created only by private
`init`, which `sui::test_scenario` cannot invoke. Without a way to stand these
up, no test could exercise the access chain at all. One line was added per
module:

    #[test_only] public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

at identity.move:174, audit.move:162, trust.move:485, policy.move:251 and
cap_token.move:299. `#[test_only]` items are stripped from the published
package, so this does not widen the deployed API.

---

# Part B — Java plugin (`plugin/src/main/java/org/eclipse/om2m/sui/`)

## B1 — unsigned gossip bypassed authentication entirely

**Problem.** The authentication block in `TrustGossip.handleObservation` sat
*inside* `if (signed) { ... }`. Omitting the two signature fields did not fail
the check — it skipped it, and the observation was ingested as if authenticated.
Stripping a signature was strictly easier than forging one.

**After** (TrustGossip.java:239): an absent signature or pubkey is a hard reject
before any verification is attempted.

**Verification.** Structural (an early `return` guard). Observed at runtime in
the membership-test log output as the `B1` reject path. No dedicated unit test.

## B2 — a forgery was charged to the victim, not the forger

**Problem.** When the address-binding check failed — the address derived from
the shipped public key did not equal the claimed `observerAddr` — the garbage
flag was raised on `obs.observerAddr`, the **claimed** address. Anyone could
therefore drive an honest node's score down simply by signing junk in that
node's name. The penalty mechanism was itself an attack primitive.

**After** (TrustGossip.java, B2 block following the verify): the flag is charged
to the cryptographically derived signer. If the signature does not verify at
all, the message cannot be attributed to anybody and nobody is penalised. The
derived address must additionally be a cluster member before anything is
recorded, so an attacker cannot spawn unbounded tracked peers in
`BehaviourObserver` with throwaway keys.

**Verification.** Structural. No dedicated unit test.

## B3 — mean aggregation and a hardcoded agreement threshold

**Problem.** Peer signals were combined with an arithmetic mean, which a single
Byzantine observer can move arbitrarily by reporting an extreme value. The
agreement threshold was the literal `2`, which carries no fault bound — it is
simultaneously too strict for a 2-node cluster and far too lax for a large one.

**After.** Median over the value signals, and a per-aggregation threshold
k = floor((n-1)/2) + 1 over the admitted observers (TrustConfig.java:147).

**Verification.** `TrustAggregationTest`:
`medianIgnoresOneByzantineExtreme`, `medianOfEvenCountIsMeanOfTwoCentralSamples`,
`medianOfSingleSampleIsThatSample`, `medianReadsTheRequestedSignal`,
`agreementThresholdIsStrictMajorityOfObservers`,
`agreementThresholdToleratesFloorNMinus1Over2Faults`.

## B4 — nodes graded themselves

**Problem.** `observer == target` observations were both published and read. A
node's own opinion of itself is unattested input it fully controls, so it could
inflate its own peer aggregate (or deflate it by omission).

**After.** Excluded on both paths — on publish (TrustGossip.java:163) and on
ingest.

**Verification.** Structural (a `continue`/filter on each path).

## B5b — a non-submitter stamped on-chain state it had never read

**Problem.** On a tier crossing, a node that was not the elected submitter
optimistically set `lastOnChain` from its own local EMA. That made
`prevTier == newTier` on the next tick and permanently stopped the retry. If the
real submitter's write failed — or it never believed it was the submitter, which
the local-view election allows — the crossing was silently lost forever, with
no error anywhere.

**After** (TrustScoringEngine.java:192): the non-submitter reads real on-chain
state via `ptb.readTrustScore(target)`. If the write landed, `lastOnChain`
matches and it goes quiet; if it did not, the crossing stays pending and is
re-evaluated next tick. A failed read also keeps the crossing pending rather
than clearing it.

**Verification.** Structural. Needs live multi-node behaviour to exercise —
see "Not verified in this environment".

## B6 — timestamp-only replay ordinal locked out a restarted node

**Problem.** Replay protection ordered observations by `producedAtMs` alone, so
the rule was "strictly increasing timestamps". A node whose clock moved
*backwards* across a restart — a Pi with no RTC, NTP not yet converged — would
emit observations below its own high-water mark and be rejected as a replayer
**permanently**, with no recovery path. Liveness was sacrificed to a safety
check.

**After.** The ordinal is the lexicographic pair `(epoch, producedAtMs)`, where
`epoch` is a persisted monotonic restart counter (`ObserverEpoch.java`,
`nextEpoch(persistPath)`, stamped on every observation at
BehaviourObserver.java:42). A strictly higher epoch is always admitted,
regardless of timestamp. The wire format is bumped v1 -> v2
(`NodeObservation.WIRE_VERSION = "v2"`, 13 unsigned / 15 signed fields) and v1
messages are rejected rather than reinterpreted.

**Verification.** `TrustGossipReplayTest`, all 10:
`sameEpochNewerObservationIsNotReplay`, `sameEpochOlderObservationIsReplay`,
`sameEpochEqualTimestampIsReplay`, `firstObservationForPairIsNotReplay`,
`newerEpochWithLowerTimestampIsNotReplay`,
`newerEpochWithEqualTimestampIsNotReplay`,
`newerEpochWithHigherTimestampIsNotReplay`,
`olderEpochIsReplayEvenWithHigherTimestamp`, `epochSurvivesWireRoundTrip`,
`v1WireFormatIsRejected`.

The middle three are the ones that matter: a newer epoch is admitted with a
lower, equal or higher timestamp alike. See the SY5 note under "Open items".

## B9 — heartbeat health was pinned at 0 for every non-parent node

**Problem.** `recordHeartbeat` was gated on the current parent address, so only
the parent ever accumulated heartbeat samples. Every other middleware node had
a heartbeat signal of 0 — the largest single weight in the scheme — which
capped its achievable score below the top tier no matter how well it behaved.
The scoring engine could not promote a healthy non-parent node.

**After** (BehaviourObserver.java:95): heartbeat and clock-drift are recorded
for every middleware node that beats. Tier-boundary hysteresis was added
alongside (`trust.tier.hysteresis` default 2.0, `trust.tier.confirm.ticks`
default 2) so the now-mobile scores do not flap across a boundary.

**Verification.** The hysteresis logic is unit-tested in `TrustAggregationTest`:
`crossingUpwardsNeedsToClearTheBoundaryByTheMargin`,
`crossingDownwardsNeedsToClearTheBoundaryByTheMargin`,
`sameTierIsNeverACrossing`, `flappingOnABoundaryNeverCrosses`,
`zeroHysteresisRestoresTheBareBoundaryTest`,
`candidateTierMustHoldForConsecutiveTicks`.
The heartbeat-recording change itself is structural and needs a live multi-node
run — see "Not verified in this environment".

## B10 — any fresh keypair could become an "alive observer"

**Problem.** Observer admission required only a self-consistent signature: the
address derived from the shipped public key had to match the claimed observer
address. An attacker can satisfy that trivially by generating a keypair. The
consequences were two:

1. **Denominator stuffing.** Each fake observer counted toward the alive-node
   count `n`, and therefore toward the agreement threshold, so an attacker could
   make honest agreement unreachable.
2. **Submitter election capture.** The submitter is the lowest-address live
   node. By grinding keypairs for a low address, an attacker could win the
   election and then simply never submit.

**After.** A `MemberRegistry` abstraction (`MemberRegistry.java`) with an
on-chain implementation `IdentityRegistryMembers.java` that dev-inspects
`identity::is_registered` against the shared `identity::Registry`, with a cached
answer (`trust.membership.cache.ttl.ms`). Observers must be registered members;
non-members are dropped at ingest and do not count toward `n`.

**Verification.** `TrustGossipMembershipTest`, all 6:
`unregisteredObserverGossipIsDropped`,
`sameObservationFromRegisteredObserverIsAdmitted` (the controlled pair — same
observation, membership the only variable),
`failClosedRegistryDropsOtherwiseValidObservation`,
`throwingRegistryNeverAdmitsTheObserver`,
`unregisteredObserversCannotInflateTheAliveNodeCount` (the denominator property
directly), `revokedObserverStopsCountingWithoutWaitingForStaleness`.

Note the registry is **fail-closed**: an unreachable or throwing registry admits
nobody, which the last two tests pin down.

## B11 — two signals with no basis were removed

**Problem.** `mqttMismatch` (weight 5) had a setter with no caller — a
permanently-zero penalty occupying 5 of 100 points. The impersonation signal
(weight 8) was raised by the same code path that B2 corrected; once the flag is
charged to the derived signer rather than the claimed address, the signal's
original meaning no longer exists.

**After.** Both removed. Their weight was redistributed (see B12).

**Verification.** Covered by `weightsMatchTheEightSignalScheme`.

## B12 — `deniedBurst` and `ptbAbort` double-counted the same event

**Problem.** A denied access decision incremented `deniedBurst`; a PTB abort
incremented `ptbAbort`. In this architecture a denial *is* a PTB abort — these
were two normalisations of one event, so every denial was penalised twice, at
combined weight 35.

**After.** One "denied decisions" signal at weight 25
(BehaviourObserver.java:117 is its single home, fed by `recordRequest` whenever
`!granted`). The resulting 8-signal scheme, validated at config load to sum to
100 (TrustConfig.java:132-139 and the check at :230):

    heartbeat          25
    denied decisions   25
    malformed          10
    rate               10
    out-of-baseline    10   (historical)
    garbage            10
    clock drift         5
    inactivity          5
                      ---
                      100

`TrustConfig` throws if `trust.weight.*` overrides do not sum to 100.

**Verification.** `TrustAggregationTest.weightsMatchTheEightSignalScheme` and
`weightOverridesAreStillValidated`.

## A5/A6/A7 client side — both PTB builders rewritten

Both access-PTB implementations now thread the receipts between the five Move
calls instead of re-supplying forgeable parameters per step.

`ptb/PtbBuilder.java` (CLI path, `sui client ptb`), documented at lines 21-26:

    STEP 1   identity::verify(id_reg, ctx)                              -> r1 IdentityReceipt
    STEP 2   trust::require_min(r1, trust_reg, resource_id, min, clock) -> r2 TrustReceipt
    STEP 3   cap_token::validate_for_use(r2, token, op, clock, ctx)     -> r3 TokenReceipt
    STEP 4   policy::evaluate(r3, policy_reg, trust_reg, clock)         -> r4 PolicyReceipt
    STEP 5+6 evaluator::decide_and_log(r4, audit_trail, clock)

`sdk/NativePtbBuilder.java` (native BCS path) encodes the same five commands
with `Result(0..3)` wired into the following command's first argument
(lines 95-99 and 168-205). Steps 5 and 6 collapse into one call because the
decision is now GRANTED by construction of the chain — reaching
`decide_and_log` means steps 1-4 all passed.

**Verification.** Compiles clean. Not exercised against a live package — there
is no v8 package to call.

---

# Part C — scripts and config

## C1 — proof and bench scripts described a write as a read

**Problem.** `proofs/03_capability_tokens.sh`, `04_atomic_ptb.sh`,
`05_policy.sh`, `08_audit_trail.sh` and `bench/bench_access_latency.sh` all send
`"op":1` — the oneM2M **CREATE** code — which `SuiDasService.mapOperation` maps
to the `OP_WRITE` bit of the token mask. Their comments and echoed banners
called it a read. The published latency figure was therefore being described as
read-authorization latency when it measures write authorization.

**Fix.** The *labels* were corrected; the op **value was deliberately left at
1**. The measured numbers were taken with `op=1`, so changing the value would
invalidate them — only the wording was ever wrong. `bench_access_latency.sh`
carries an explicit instruction not to "fix" it to 2, and now reports
"write authorization (CREATE)". Each proof script gained a four-line note
distinguishing `"op":1` (the oneM2M operation being authorized) from
`X-M2M-Operation: 5` (NOTIFY, the header OM2M needs to route the decision
request into the DAS) — neither of which is a read.

Separately, `08_audit_trail.sh`'s banner "read the tx's events" was changed to
"inspect the tx's events", since "read" there is unrelated to the oneM2M
operation and was a collision of vocabulary.

**Verification.** Comment/label-only. `git diff` shows no change to any `op`
value or to any request-body field.

## C2 — `SuiDasService.java`

**What is actually in the working diff:** two deletions, no insertions — the
removal of the `obs.recordPtbResult(...)` call at both call sites (the
`PtbBuilder` path and the native path). This is the client half of **B12**: with
`deniedBurst` and `ptbAbort` merged, `recordRequest` is the single recorder and
the second call would double-count.

**Reported honestly:** no ACP / dynamic-authorization-consultation routing
change to `SuiDasService.java` is present on this branch. If one was intended,
it has not been written. The file also cannot be compiled here (see below), so
even the two-line B12 change is **unverified** and must be compiled in a tree
that has the OM2M jars.

## C3 — `scripts/env.sh` described v7 as an upgrade of the v1-v6 line

**Problem.** The file carried the comment "v6 package (current deployed)" and
"`$PKG` above (v1) is the type-root and stays fixed across upgrades". That rule
is correct for an upgrade lineage and wrong here: `move/Published.toml` records
v7 with `published-at = original-id = 0x56601695...0213d43` and `version = 1` —
a **fresh, independent publish** with its own type root, object lineage and
UpgradeCap. Following the stale comment means passing `$PKG` as the type root
for v7 objects, which v7 functions reject.

**Fix.** `$PKG` is relabelled RETIRED (type root of the v1-v6 line only, kept
solely to resolve historical digests), the `PKG_V7` block states the
fresh-publish relationship with its `Published.toml` evidence, and a TODO
records that the v8 publish will invalidate every id in the file.

**Verification.** Documentation-only; checked against `move/Published.toml` and
`move/Published.toml.v6-backup`.

## C6 — `config/sui.mappings.properties` created, with every key colon escaped

**Problem.** `SuiConfig.load()` documents keys of the form

    addr.<originator>=<0x sui address>
    token.<originator>::<resource-id>=<0x token object id>

so the keys contain colons by design, and this testbed's main originator is
`admin:admin`, which contains another. `java.util.Properties` treats `:` as a
key/value separator exactly like `=`, splitting on the first bare one — with no
parse error and no log line.

**Fix.** The file is created with every literal colon in a key written `\:`, so
the `::` separator appears as `\:\:`, and is annotated with the trap.

**Verification.** Verified against `java.util.Properties` on JDK 21 using
`SuiConfig`'s exact parsing logic. The failure modes are documented in full in
`RECOVERY.md` under "sui.mappings.properties - escape every colon in a KEY".

---

# Test inventory as observed

Move — 66 tests, `sui move test`, all passing:

| Module (`move/tests/`) | Tests | Covers |
|---|---|---|
| `evolution_lifecycle_tests.move` | 20 | A9, tier mapping, cap_token validate/revoke |
| `receipt_chain_tests.move` | 13 | A3, A4, A5, A6, A7 |
| `admin_cap_validity_tests.move` | 9 | A1, A2, A8 |
| `failover_lease_tests.move` | 9 | A10 (both writers) |
| `trust_revocation_tests.move` | 8 | A12, TR7, self-scoring |
| `policy_tests.move` | 7 | PO1, PO2 |

Java — 33 tests, all passing:

| Class | Tests | Covers |
|---|---|---|
| `trust/TrustAggregationTest` | 14 | B3, B9 hysteresis, B11, B12 |
| `trust/TrustGossipReplayTest` | 10 | B6 |
| `trust/TrustGossipMembershipTest` | 6 | B10 |
| `failover/FailoverManagerGasTest` | 3 | FM5 gas-exhaustion detection |

Reproduction commands are in `TESTING.md`.

---

# Source-level findings still open

These were found while making the changes above and are **not fixed**. They are
recorded so they are not mistaken for verified-clean code.

1. **`audit::resize` shrink path is unimplemented.** The comment at
   audit.move:97 says "Truncation if shrinking is handled on next log call",
   but `log` only takes the `push_back` branch when `len < ring_size`
   (audit.move:142). After a shrink, `len >= ring_size`, so it overwrites at
   `next_slot % ring_size` and the entries past the new `ring_size` are never
   reached — they stay stale in the vector while `count()` (which returns
   `next_slot`) keeps incrementing. Impact is confined to the forensic cache;
   the emitted `AccessLogged` events remain canonical and correct.

2. **`failover::set_trust_gate` reuses a misleading abort code.** On a
   cap/cluster mismatch it aborts `E_NOT_REGISTERED` (1) at failover.move:290.
   The condition is "this cap is not for this cluster", not "not registered".
   Diagnostic quality only.

3. **Unchecked addition in `trust::assert_write_allowed`.**
   `entry.last_update_ms + MIN_INTERVAL_MS` (trust.move:156) can overflow, but
   only when `last_update_ms` is within 60 s of `u64::MAX`. Unreachable with
   real `Clock` values; cosmetic.

4. **Redundant cap validation.** `increase_guarded`/`decrease_guarded` call
   `assert_cap_valid` and then delegate to `increase`/`decrease`, which call it
   again. Harmless; two asserts where one suffices.

5. **`move/build/` holds a stale pre-v8 snapshot.** It still contains the
   deleted A11 text — `move/build/om2m_access/sources/evolution.move` and
   `.../evolution_lifecycle_tests.move` both match `SubCapability`. It is
   compiler output, not a source of truth, but anyone grepping the tree will
   find the removed struct there.

6. **A7 is not provable by in-package Move tests.** See the limit-of-claim note
   under A7.

7. **A6's reorder/skip half is compile-time, not runtime.** See the
   limit-of-claim note under A6.

---

# Not verified in this environment

Stated explicitly so nothing here is read as more than it is.

**Two Java files do not compile here.**
`das/SuiDasService.java` and `SuiPluginActivator.java` fail with
`package org.eclipse.om2m.commons.constants does not exist`,
`package org.eclipse.om2m.commons.resource does not exist`,
`package org.eclipse.om2m.interworking.service does not exist` and
`package org.osgi.framework does not exist`. The four
`org.eclipse.om2m:*:1.1.0` jars are not in Maven Central, so there is no
Maven-resolvable build for the full plugin on this machine. **This is an
environment limitation, not a code defect** — every error is an unresolvable
import or a symbol from one, none is a type or logic error in our own code. But
it does mean the C2/B12 change in `SuiDasService.java` is **unverified** and
must be compiled in a tree that has the OM2M jars in its local `~/.m2`.

**ACP consultation routing.** Whether the DAS is actually reached through
OM2M's in-JVM `Redirector` / dynamic-authorization-consultation path cannot be
tested here. This is the same unresolved blocker documented in `RECOVERY.md`
("The blocker (unresolved)" — the request primitive is built and routed to
`sui-das` but `doExecute` is never reached, the denial happening in OM2M's core
Controller before the plugin runs).

**OSGi bundle packaging** (`maven-bundle-plugin`) was never exercised. Import/
export headers, the Equinox EE filter and the Java 1.8 bundle target are
unchanged by this batch but unvalidated by it. The three new trust classes
(`ObserverEpoch`, `MemberRegistry`, `IdentityRegistryMembers`) live in the
already-exported `org.eclipse.om2m.sui.trust` package, so no manifest change is
expected — but that expectation is untested.

**Everything requiring the live cluster or a published package:**
- the v8 publish itself, and therefore every on-chain claim about v8
- B5b's on-chain read path (`readTrustScore`) and the retry behaviour it enables
- B9's live multi-node heartbeat accumulation, and hysteresis under real score
  movement
- B10's `identity::is_registered` dev-inspect against a real fullnode
- both rewritten PTB builders against a real package
- any end-to-end GRANT/DENY, latency or gas figure

No digest, no gas number and no latency number appears in this document, because
none was produced. The measured figures in `MEASUREMENTS.md` and
`benchmark-results-30may2026.txt` were taken against earlier packages and are
not re-validated here.
