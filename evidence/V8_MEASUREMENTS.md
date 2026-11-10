# v8 measurements: proofs, latency, gas, failover (2026-11-10)

Measured on the live 3-Pi testbed running package v8
(`0x88f0b0f7…62f1`, cluster `0xe49d6c5f…602f`; every ID is in
`deploy/v8/deployment.env`). The plugin bundle was `7fa41e66` on all three nodes,
which includes two failover fixes found during this run (§4). Raw data, logs and the exact
commands are in [`v8-measurements/`](v8-measurements/), see
[`COMMANDS.md`](v8-measurements/COMMANDS.md).

**What changed versus the pre-v8 numbers in the paper.** Every request below is an *ordinary*
oneM2M request (no `X-M2M-Operation: 5` NOTIFY, no DAS URL). The static ACPs grant
`Csensor-001` nothing, so OM2M consults the DynamicAuthorizationConsultation, which calls the
Sui DAS. The DAS then sends one five-command PTB:
`identity::verify → trust::require_min → cap_token::validate_for_use → policy::evaluate → evaluator::decide_and_log`.
The old benchmarks drove the DAS directly over NOTIFY and timed only a CREATE decision.
Treat those numbers as superseded.

---

## 1. Proofs against v8: 10 of 10 pass

Each proof now ends with a `RESULT` line that counts the assertions that held. Every
transaction is in [`proofs_v8.csv`](v8-measurements/proofs_v8.csv) with its digest, outcome
and net gas, and the full output is in `proof_NN.log`. All shared code and IDs are in
`proofs/lib_v8.sh`: node-signed calls run inside each node's container with its own key;
publisher calls run in WSL.

| # | Concept | Assertions | Key on-chain evidence (digest → outcome) |
|---|---|---|---|
| 01 | Self-scoring | 2/2 | bypass module fails to compile (`E04001`, `trust::increase` is `public(package)`); `AQgvoUaw…` rpi3 raising itself → **abort 4** |
| 02 | Peer scoring + A12 | 5/5 | `HPh4KkrZ…` rpi1 −3 on rpi2 ✓; `623koyjY…` self **4**; `22pMAWeE…` Δ16 **6** (E_DELTA_TOO_LARGE); `3f86ohQf…` 2nd write <60 s **7** (E_RATE_LIMITED); `5fRLxEwX…` restore ✓ |
| 03 | Capability token + A4 | 2/2 | ordinary RETRIEVE → HTTP 200, GRANT `RsZ5wWqD…`; rpi1 spending rpi3's token → **rejected before execution** (Sui owned-object rule; no digest, no gas) |
| 04 | Atomic PTB + A6 | 3/3 | GRANT `3iQkde2L…` = 5 MoveCalls, each taking `Result(n-1)`; skipping `policy::evaluate` → `TypeMismatch` (`64eTujpk…`); a lone `identity::verify` → `UnusedValueWithoutDrop` (`FAFuxRgv…`) |
| 05 | Policy + A5 | 2/2 | ordinary DELETE (op not in mask) → **HTTP 403, Sui DENY**, AE intact; same chain signed directly → `3CV9QeHw…` **abort 4** (E_OP_NOT_ALLOWED) |
| 06 | Failover + A10 | 8/8 (run 3) | `B9bG1yva…` lease 3,600,001 ms **7**; `DpjwHuP5…` non-parent renew **4**; `7vsosNgr…` claim on valid lease **3**; `Go56XbAK…` renew 0 ✓; `DkQb91bc…` claim ✓ (epoch 3→4); `63goE4tf…` race **3**; new parent anchored by itself |
| 07 | Evolving token + A9 | 9/9 | dedicated proof token `0xa1989b97…`; trust −11 (`6FbJv4Uq…`) → `evolve` `AfEKyr5B…` mask **15→7** on the same object; restore `3GUzu53f…` → `Ac3E6Ujx…` **7→15** |
| 08 | Audit trail + A7 | 3/3 | GRANT `7oEX73yF…` → `AccessLogged`, trail `next_slot` 7→8; forged `audit::log` / `evaluator::log_denied` → `NonEntryFunctionInvoked` (`92uvTW4v…`, `29czbtFe…`) |
| 09 | Revocation + A1/A2 | 7/7 | throwaway cap `8UYKm2m6…` granted, `62Je1jeB…` revoked (valid True→False); with it: score write **5**, `grant_admin_registered` **5**, `add_node` **5**; `7pxyku13…` burned. Production caps untouched |
| 10 | Live logs | 5/5 | startup order, on-chain decisions, trust engine, signed gossip, parent anchoring |

**Proofs whose premise changed (findings, not failures):**
- **A4:** the attack can no longer be built. Sui refuses a transaction in which rpi1 uses an
  object owned by rpi3, before execution. The Move-level `E_NOT_TOKEN_OWNER` check is now
  defence in depth. It matters only if a token is ever wrapped or transferred, because
  `CapToken` has `store`.
- **A6/A7:** step-skipping, dangling receipts and direct audit writes are no longer aborts with
  a code. The PTB type checker rejects them (`TypeMismatch`, `UnusedValueWithoutDrop`,
  `NonEntryFunctionInvoked`). These still execute on-chain and the sender pays gas.
- **07:** the v7 proof dropped trust by 35 in one write. A12 caps a write at 15, so the
  demotion now crosses one tier boundary (90). It also uses a dedicated token: evolving the
  production token would have widened it to `ADMIN|DELETE`, because rpi3 is at 100.
- **09:** the v7 proof revoked rpi2's real cap and left it broken. It now uses a throwaway cap
  and also checks the A1 and A2 consequences.

## 2. End-to-end latency on the real DAC path

Measured on rpi3 itself, with curl to `127.0.0.1:8282`. That is the full oneM2M
request/response a client sees, minus the network hop to the Pi.
[`latency_requests.csv`](v8-measurements/latency_requests.csv) has every sample;
[`das_decisions.csv`](v8-measurements/das_decisions.csv) has the plugin's own log line and
digest for each decision; [`latency_summary.csv`](v8-measurements/latency_summary.csv) has
the statistics. Percentiles are nearest-rank.

Read and write requests on the DAS were alternated 3 s apart. A given
(originator, resource, op) key therefore repeats every ~8.6 s, longer than the DAS GRANT
cache (`sui.das.cache.ttl.ms=5000`). The plugin log confirms **201 on-chain GRANTs** for
the 200 cold samples plus one warm-up: every `dac_*` sample was a real transaction.

| Series (n = 100 each, all HTTP 200) | p50 ms | p95 ms | p99 ms | mean ± sd ms | min–max ms |
|---|---|---|---|---|---|
| Baseline RETRIEVE (static ACP, no Sui) | 4.1 | 6.8 | 8.6 | 4.4 ± 1.2 | 3.2–10.4 |
| Baseline UPDATE (static ACP, no Sui) | 6.9 | 10.6 | 15.4 | 7.4 ± 2.1 | 5.1–17.6 |
| **DAC RETRIEVE → Sui GRANT (op READ)** | **1320.7** | **2129.5** | **2459.9** | 1506.4 ± 327.0 | 1239.9–2691.9 |
| **DAC UPDATE → Sui GRANT (op WRITE)** | **1339.3** | **2344.0** | **2806.6** | 1520.1 ± 360.0 | 1250.9–2818.8 |
| DAC RETRIEVE, DAS cache hit (no chain) | 3.6 | 7.5 | 8.4 | 4.2 ± 1.4 | 3.0–9.3 |
| *DAS-internal, read (PTB build + sign + execute)* | 1316 | 2124 | 2454 | 1497.8 ± 322.1 | 1235–2686 |
| *DAS-internal, write* | 1326.5 | 2333 | 2797 | 1508.8 ± 360.1 | 1240–2808 |

How to read these numbers:
- **The chain accounts for almost all of it.** The DAS-internal time is within about 10 ms of
  the end-to-end time. OM2M plus the DAC hop add about as much as a baseline request.
- **Reads and writes cost the same.** Both run the same PTB; only the op bit differs.
- **The distribution is skewed, not normal.** 70 % of decisions finish within about 1.37 s; the
  tail (1.6–2.8 s) comes from waiting on testnet checkpoints and the GraphQL indexer. Report
  p50/p95/p99, not mean ± sd.
- **The 5 s GRANT cache brings a repeat decision back to baseline (3.6 ms p50).** That is a
  freshness trade-off: a revocation takes up to 5 s to bite on a cached key. DENYs are never
  cached.

## 3. Gas per operation (from real transaction effects)

Net = computation + storage − rebate, in MIST (1 SUI = 10⁹ MIST), read from GraphQL for every
digest: [`gas_per_tx.csv`](v8-measurements/gas_per_tx.csv),
[`gas_summary.csv`](v8-measurements/gas_summary.csv). Testnet reference gas price was 1000
MIST/unit, so every transaction pays the 1,000,000 MIST computation floor.

| Operation | n | net MIST (median) | SUI | notes |
|---|---|---|---|---|
| **DAS decision, GRANT (read or write)** | 201 | **1,600,134** | 0.0016 | storage 73.9 M / rebate 73.3 M: each GRANT rewrites the 512-slot `AuditTrail` ring (~9.7 KB) |
| DAS decision, DENY (PTB executes and aborts) | 1 | **1,000,872** | 0.0010 | `E44Q4j6a…`: the full 5-command PTB, aborted in `validate_for_use`. **Denials are paid** (§5, F3) |
| Trust write (`increase/decrease_guarded`) | 4 CLI + 2 plugin | **1,000,600** | 0.0010 | |
| `claim_parent` (accepted) | 3 CLI + 1 plugin | **1,000,276** | 0.0010 | |
| `renew_lease` (lease anchor) | 3 CLI + 6 plugin | **1,000,276** | 0.0010 | |
| `set_parent_poa` (PoA publication) | 3 (plugin) | **1,000,473** | 0.0010 | |
| Any aborted call (codes 3–7) | 22 | 1,000,276–1,000,872 | ~0.0010 | an abort costs as much as a success |
| `evolve` | 3 | 1,000,725 | 0.0010 | |
| one-off: `evolution::bootstrap` / `cap_token::mint` / `grant_admin_registered` | 1 each | 5,134,712 / 3,128,232 / 2,535,906 | | new objects/fields pay storage |

Since every paid abort costs as much as a success, the v8 claim gate (free reads before
claiming) is worth having: the pre-v8 watchdog would have paid for about 240 doomed
claims per follower per failover, about 0.24 SUI each.

## 4. Failover

One real failover with nothing done by hand: the parent's CSE container was stopped
(`docker stop`), and the followers' plugins did everything else.
[`failover_20261110T025206Z.csv`](v8-measurements/failover_20261110T025206Z.csv) has the
timeline (chain reads plus every relevant plugin log line); the script is
`bench/bench_v8_failover.sh`.

| t (s after stop) | Event |
|---|---|
| 0 | rpi2 (parent, epoch 4) stopped; its last anchored lease had **642.2 s** left |
| 23.9 | rpi3: `Parent silence detected (16619 ms); claim gate: LEASE_VALID` (15 s heartbeat timeout + 5 s tick). **No transaction is sent while the lease runs.** |
| 642.2 | lease expires on-chain |
| 645.7 | rpi1: gate → `CLAIM` (2 s skew margin, next 5 s tick) |
| **647.3** | **rpi1 `CLAIM ACCEPTED`** (`77CzuFGE…`, 1.56 s), epoch 4 → 5. **5.0 s after lease expiry** |
| 648.9 | rpi3's claim → abort 3 (`xvCaeyZm…`): one winner. **2 claims in total** |
| 649.9 | rpi1 anchors a 20 min lease (`Ee3YJphG…`; one stale gas-coin rebuild, absorbed by `withStaleRetry`) |
| 652.6 | rpi1 publishes its PoA (`E92yUy2b…`) |
| 657.4 | rpi3 corrects its PoA from the deposed parent's `…201` to `…200` (the F2 fix, see §5, live) |
| +34 after restart | old parent rpi2 restarted and **rejoined as a follower** of rpi1, no claim |

**Time to a new parent = remaining lease + ~5 s.** The lease dominates: it is anchored for
20 min (anchor every `failover.lease.anchor.period.ms=600000`, length 1,200,000 ms). The
worst case is therefore ~20 min plus 5 s, the best case ~5 s after expiry, and for a uniformly
random stop time the expected wait is ~15 min (the remaining lease is between 10 and 20 min
at any moment). Shortening the anchored lease shortens takeover in proportion, at one
`renew_lease` (1.0 mSUI) per anchor period.
**Gas for the whole failover: 4 transactions, ~4.0 mSUI** (claim, losing claim, anchor, PoA).

`scripts/v8/04_cutover.sh verify` afterwards: all three CSEs 200, DAS and DAC AE 200 on every
node, v2 gossip from all three addresses, and the C2 ordinary RETRIEVE granted on-chain
([`verify_after.log`](v8-measurements/verify_after.log)). rpi2's log shows OM2M
`ConflictException: Already registered` right after its restart. That is the boot-time DAS
provisioning finding the AE already created (409), and it is harmless.

**Forced takeover (proof 06).** When the parent renews its lease to 0 and a follower claims
with the CLI, the claim lands in ~1.5 s, and the new parent's plugin anchors its own lease
within one 15 s chain-sync period (runs 2 and 3). Before the F1 fix it never did (run 1).

## 5. Findings from this run

| # | Finding | Status |
|---|---|---|
| **F1** | **A node named parent on-chain other than through its own successful claim never took up parent duties.** For example, a claim that landed although the client saw an error or timeout, or one signed outside the plugin. Its 60 s claim lease lapsed and was never anchored, and nobody noticed, because the deposed parent's presence beats kept every watchdog quiet. Seen live in proof 06 run 1 ([`proof_06_run1.log`](v8-measurements/proof_06_run1.log): `cluster did not converge`, lease −77 s). | **Fixed and deployed (bundle `7fa41e66`).** Every node re-reads the cluster each `failover.parent.selfcheck.period.ms` (15 s, a free GraphQL read) and starts parent duties when the chain names it (`FailoverManager.shouldTakeUpParentDuties`; `ParentReconcileTest`, mutation-checked). Verified live in proof 06 runs 2 and 3 (`Chain names this node parent … taking them up now`). |
| **F2** | **Followers kept the deposed parent's PoA.** The on-chain PoA is not bound to the parent that set it, so right after a takeover it still holds the old parent's URL until the new parent publishes. `onParentChanged` read it in that window and kept it. Seen live after the first redeploy: rpi1 and rpi3 wrote `…203` while rpi2 was parent. | **Fixed and deployed** (`followParentPoa` on every sync; `poaNeedsUpdate` tests, mutation-checked). Verified live in the failover run (t = 657 s above). **The contract-level fix is a v9 candidate, handed to the v9 work:** `claim_parent` should clear the PoA field, or the PoA should be stored together with the address that set it. |
| **F3** | **DENYs are executed on-chain and paid**, about 1.0 mSUI each (`E44Q4j6a…`, FAILURE). A mapped originator repeating a disallowed op drains the DAS node's gas at that rate. The abort also rolls back, so **denials never reach the AuditTrail.** `log_denied_authorized` needs the `AuditAdminCap`, which the publisher holds, not rpi3. | **Open, needs a decision.** Options: simulate first (free) and submit only GRANTs, which adds one round trip per GRANT; and/or a per-originator DENY cache or rate limit; and/or transfer the `AuditAdminCap` to rpi3 so denials are logged. |
| **F4** | **Paper wording:** "every decision is recorded on the audit trail" holds only for GRANTs (F3). The trail is a single shared object holding a 512-slot ring (~9.7 KB) that every GRANT rewrites. That puts 73.9 M MIST of storage through the gas budget each time (mostly rebated), and serializes all GRANTs on one shared object. | For the paper. |
| **F5** | The node's CLI and its running plugin spend the same address's gas coins, so a CLI transaction can be built on a coin version the plugin just consumed (proof 06 run 2, one `[FAIL]`). | **Fixed in the harness:** `proofs/lib_v8.sh` rebuilds on a stale version, like the plugin's `withStaleRetry`. |
| **F6** | `bench/provision_das.sh` (legacy) re-adds `Csensor-001` with acop 63 to `acp_admin`, which is the static bypass the v8 rollout removed. | **Fixed:** it refuses to run unless `LEGACY_V7_PROVISION=1`. |
| **F7** | After `cleanup`, `04_cutover.sh rollback` had nothing to roll back to and said "nothing to roll back". | **Fixed in the script:** it now recreates v7 from `:rpiN-v7-final` (the snapshot keeps the v7 entrypoint, Cmd and Env; checked). **That path has not been exercised.** |
| F8 | After the redeploys, rpi2's trust engine keeps logging `rpi1 tier 4->3 NOT yet on-chain … retrying` (32 lines in 30 min; it is not the elected submitter, so it is waiting). The restarts lowered rpi1's EMA. | Observation; not investigated. |
| F9 | `proofs/README.md` contains an unrelated README (an IMDb database project). | Not touched; flagged. |
