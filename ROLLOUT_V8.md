# v8 rollout plan — doing it so it stays up

This is the plan for moving the live testbed from package **v7** to **v8** (the
A1–A12 / B1–B12 / C1–C6 security batch plus the GraphQL transport migration).
It's written for durability: every step should still hold after a reboot, a
container recreation, or someone redeploying in six months.

Status markers: `[x]` done and verified, `[ ]` pending, `[!]` needs Mouaz.

---

## Why this can't be a partial deploy

These were all checked against the live system on 2026-11-10:

- **The plugin and the package must change together.** On-chain v7 still has
  the old signatures. For example, `identity::verify(Registry, address)`
  returns nothing, and `policy::evaluate(..., u64, Clock)` takes a bare trust
  score. The branch plugin calls the v8 receipt-chain API instead, so deploying
  it against v7 makes every access decision abort.
- **All three nodes must switch at the same time.** The branch's gossip wire
  format is **v2** (it adds the B6 epoch), and the live nodes speak **v1**.
  Mixed-version nodes can't read each other's observations.
- **The container runtime is Java 1.8.0_492.** Anything compiled against a
  newer API set fails at runtime with `NoSuchMethodError`. `FailoverManager`'s
  lease anchor was calling `List.of` (Java 9+); that's now fixed, and the whole
  plugin compiles with `--release 8`.

## What was already broken on the live system (found 2026-11-09/10)

| Problem | Cause | Status |
|---|---|---|
| No on-chain reads or writes at all | Sui removed JSON-RPC from public fullnodes; plugin used it | [x] code migrated to GraphQL (60/60 tests, all reads verified live) — not yet deployed |
| MQTT mesh down since 2026-06-16 | rpi1/rpi2 rebooted; `mosquitto` had `restart=no` | [x] brokers back up, `restart=unless-stopped` on all 3, live cross-node traffic confirmed |
| Failover parent lease expired 2026-07-06 | Unknown. rpi1 logs show repeated `Parent duties stopped (deposed)`. It's **not** the `List.of` bug, since that code never ran | [ ] investigate after cutover; transport + mesh both affected it |
| rpi3 trust score reads 0 (gate is 50) | **Design bug, confirmed in code.** Scores decay 1 pt/day on-chain, but the engine writes only on tier *crossings*, so a stable, healthy node is never refreshed and decays below the gate. Starting at 80, every node would fail after ~30 days | [x] engine re-attests fresh targets every 12 h (re-anchors even at delta 0); silent targets are never written upward, so TR4 still applies to dead nodes. 60-simulated-day test; mutation-checked |
| **Any write erased all accumulated decay, and one write could move the effective score far beyond 15** | `trust::increase/decrease` applied the delta to the *stored* score, not the decayed one. Example: stored 80, effective 20 after 60 days; `increase(1)` → **81 (+61)**. That broke TR4 and the paper's TR8 ("at most 15 points per write") | [x] **fixed in Move before publish**: delta now applies to `decayed()`. 7 new tests; mutation-checked (6/7 fail on old code) |
| Engine never converges on large changes | `submitOnChain` sent the full delta; anything >15 aborts `E_DELTA_TOO_LARGE` on every tick, and each abort costs gas | [x] writes capped at 15 and stepped toward target (80→65→50→35→30, 0 aborts); learned cap halves on abort 6. Mutation-checked |
| Engine writes inside the 60 s window | 1 s tick, no pacing, so follow-up writes abort `E_RATE_LIMITED` (paid failures) | [x] per-target pacing ≥ 65 s, checked before the chain read; abort 7 backs off; other failures back off exponentially up to 1 h. Mutation-checked |
| No parent PoA on-chain | Nothing ever called `set_parent_poa` on the v7 cluster | [ ] parent sets it after cutover |
| rpi1 container log is 2.6 GB and growing | Docker `json-file` driver with no rotation | [ ] recreate containers with `--log-opt max-size` |
| All 3 containers report image `:rpi1` | `:rpiN-v6` were `docker commit` snapshots; the containers still point at the tag `DOCKER.md` calls **STALE**. Recreating one from its own config brings back the FM4 bug | [ ] recreate from `:rpiN-v8` |
| Broker config not reboot-durable | `/tmp/mosquitto-mesh.conf`; the `@reboot` cron restores only the `sui.*` files | [ ] add broker config to the durable store + cron |

## Decisions made

- **The publisher is `0xb87fb2af…`**, in WSL Ubuntu on Mouaz's laptop
  (`~/.sui/sui_config`, CLI 1.74.0, confirmed it can still reach testnet). It
  stays the account the paper describes. The key never leaves that machine.
- **v8 is a fresh publish.** A6/A7 change signatures and visibility across 5
  of 8 modules, which a compatible upgrade can't do.
- **The quorum mechanism (paper limitation 2) comes after, as v9.** It's
  additive (a new module, new functions, one-line body guards), so it can ship
  as a *compatible upgrade* of v8. That's the design's own recommendation, not
  a shortcut. It still requires moving the UpgradeCap to a multisig, or the
  threshold can be replaced by whoever holds the cap.
- **Requester semantics stay as deployed.** Both originators map to rpi3's
  address, and the DAS signs with that key. v8 makes that binding honest (the
  DAS can only act as accounts it holds keys for). True per-sensor on-chain
  identity would need per-originator accounts plus sponsored transactions.
  That's recorded as an open design question for the paper, not folded into
  this rollout.

---

## Phases

### A. Code readiness (local) — done
- [x] Move: `sui move build` exit 0; `sui move test` 66/66
- [x] Java: full Maven build (all 27 sources) BUILD SUCCESS; **75/75** tests incl. 15 engine chain-write tests against a fake chain that models trust.move; bundle sha256 `4eefa1be…`
- [x] Transport: GraphQL migration, every read path verified live against real objects
- [x] Java 8 runtime hazard (`List.of`) removed

### B. Reproducible bundle build — in WSL on the publisher laptop — done
The deployed bundle (md5 `e1950881…`) is byte-identical to
`~/sui-om2m/plugin/target/*.jar` in WSL. WSL is therefore the canonical build
environment: Maven 3.9.12, JDK 25, and all four `org.eclipse.om2m:*:1.1.0`
jars installed in `~/.m2` (they aren't on Maven Central).
- [x] `scripts/build_bundle.sh`: `mvn clean package`, then checks that every class is Java 8 bytecode, then writes a sha256
- [x] **Every source compiles**, including `SuiDasService` and `SuiPluginActivator`, which no other environment could compile. 60/60 tests pass under Maven.
- [x] `Import-Package` is **identical** to the deployed bundle. `Export-Package` differs only in attribute order. All 50 classes are major version 52.
- [x] **Java 8 API guard:** `animal-sniffer` checks against the `java18` signature. `<maven.compiler.release>8` can't be used because JDK 25 dropped release 8. Mutation-tested: putting `List.of` back makes the build fail with `Undefined reference: java.util.List.of(Object[])`.

### C. Publish v8 — [!] publisher-signed, in WSL
- [x] `scripts/v8/01_publish.sh`: refuses unless the active address is the publisher; guards against a Windows-written `Move.lock`; `sui move test` must pass; sets aside v7's `Published.toml`. Parses the effects into **`deploy/v8/deployment.env`**.
- [x] **Dry run re-passed after the decay fix**: 73/73 Move tests on the publisher's toolchain, status success, **0.1460 SUI**.
- [x] **Dry run passed on live testnet** (2026-11-10, pre-decay-fix): status success, net gas **0.1459 SUI**. It created exactly the 4 shared registries, the 5 admin caps and the UpgradeCap, plus the two TR7 dynamic fields at genesis, which confirms on-chain that A1/A2 is fail-closed from the first transaction.
- [!] Real publish: `bash scripts/v8/01_publish.sh --execute` in WSL. The auto-mode classifier blocks this as a production deploy, so Mouaz runs it.
- [ ] `deployment.env` becomes the **single source of truth** for every ID. Nothing downstream is hand-edited.

### D. On-chain bootstrap — [!] mostly publisher-signed
Script: `scripts/v8/02_bootstrap.sh` (`--plan` by default, then `--simulate`, then `--execute`). It's idempotent (skips any step whose output is already recorded), records each transaction digest as soon as it lands, and stops at the first failure. Tested end to end against a stub CLI: an injected failure, a resume, then a full re-run that skipped every step. 14 steps, about 0.054 SUI estimated.
Two ordering notes:
- Run step 14 (`create_cluster`, 20-minute lease) close to the cutover, or the lease expires before any node runs v8.
- `set_parent_poa` is only ever called after a *claim*, so the initial parent never publishes its PoA. Phase F must handle that.
**Published 2026-11-10.** Package `0x88f0b0f7f3f4feb9a01e166567ca36a49ee149b9d260a0ac5cede95d89e962f1`, transaction `DfrEAmUTM7NSQs9fWJkaALJSFe9Ugbi25h5GGXv1fHeR`. The v8 API was checked **on-chain** via GraphQL: `identity::verify(Registry, TxContext) → IdentityReceipt`, `policy::evaluate(TokenReceipt, …)` with no caller-supplied score, `decide_and_log(PolicyReceipt, AuditTrail, Clock)`, and `attach_sub_capability` is gone.
- [x] Steps 1–13 simulated (all success), then executed. Each node owns **its own** trust AdminCap; both CapTokens are owned by rpi3. Verified on-chain.
- [x] Register the 3 nodes; `add_node` at 80; one `grant_admin_registered` cap per node
- [x] Policies + rpi3-owned CapTokens for `/in-cse/in-name/sui-protected-cnt` and the C2 AE `/in-cse/Csui-dac-ae`
- [x] Step 14 `create_cluster` held back with `UNTIL_STEP=13`, then run at cutover → cluster `0xe49d6c5faf37ad48ba1213258f3bf596720f25edd9f1fcf796dc6854dd15602f`

### E. Config, generated not hand-edited — done
- [x] `scripts/v8/03_gen_config.sh`: self-check passes under Python **and real `java.util.Properties`** (all 4 token keys keep `::`)
- [x] Sets `sui.graphql.url`, `sui.parent.poa=http://<own-ip>:8282/`, and `trust.{ema,epoch}.persist.path=/var/lib/sui-om2m/…` (a host mount, so the B6 epoch survives container recreation)
- [x] Durable store `~/sui-runtime-config/` is now **bind-mounted directly**, no more `/tmp` indirection. v7 config, host scripts and broker config are kept in `v7-backup-20261110/`

### F. Coordinated cutover — done (`scripts/v8/04_cutover.sh`)
Subcommands: `prepare` → `cluster` → `config` → `switch`, then `verify` · `redeploy` (v8→v8 updates) · `rollback` · `cleanup`. The container definitions exist in exactly **one** place in the script.
- [x] Rollback images `:rpiN-v7-final` snapshotted from the live containers (they carry the FM4 fix)
- [x] `:rpiN-v8` images built from the snapshot plus the new bundle, with the Equinox cache cleared. Bundle sha256 verified inside every image
- [x] Containers recreated: `restart=unless-stopped`, log rotation (CSE 50 MB×5, broker 10 MB×3), durable mounts
- [x] Host provisioning (`provision-das.sh`, `das-watchdog.sh`) extended with the C2 DAC wiring, so it survives reboots. **Removed `Csensor-001`'s acop-63 grant on `acp_admin`**: that static grant let it bypass the chain wherever `acp_admin` was attached. Nothing depended on it (the ESP32 bridge writes as `admin:admin`).
- [x] Initial parent publishes its PoA. `FailoverManager` now publishes on taking up parent duties and re-checks on every anchor.

### Fixes found *during* cutover (all deployed, tested, mutation-checked)
| Problem | Fix |
|---|---|
| **MQTT bridge loop.** The full-mesh `both` bridges formed a cycle; with no TTL, messages were re-forwarded forever. Measured **212,929 deliveries per 8 s, only 110 distinct**. Ghost traffic from long-stopped v7 publishers was still circulating. Looping heartbeats could keep a dead parent "alive". | Per-origin topics (`…/<cluster>/<self>`) plus bridges that forward only the node's own subtree, outward. **After: 52 messages / 52 distinct (1.0×).** |
| **Forgeable heartbeats.** The sender address was self-declared and unauthenticated, so any node could forge the parent's beats and block failover indefinitely. | `SignedBeacon`: Ed25519 signature bound to the sender address (`hb2` format), plus a freshness window, so a replayed or looped beat can't keep a parent alive. |
| **Lease anchor went through a 200 MB CLI** pinned to an old protocol version. If it failed silently, the lease expired. | Native `renewLease` (same verified path as claims). First anchor runs immediately. Clamped to `MAX_LEASE_MS`. |
| **Claim storm.** The watchdog claimed on every 5 s tick, without checking the lease, so ~240 paid aborts per follower per failover. | Pre-claim gate using free reads: lease expired, trust ≥ gate, one claim in flight, exponential backoff. |
| **Stale gas-coin version** (GraphQL indexer lag). A new parent's first anchor was refused right after its claim. The same race could cause spurious DAS DENYs. | `withStaleRetry` around every transaction path (rebuild with fresh reads; real aborts are never retried), plus quick anchor retries. |
| `prepare`'s FM4 check needed a running container | Reads `config.ini` from the v7 snapshot image instead |

Plugin tests: **101/101** (from 33 at the start of the session). Every fix above is mutation-checked.

### G. Verification, all on the live system
- [x] Gossip: per-origin topics, signed `hb2` heartbeats, no amplification
- [x] Trust: scores move on-chain. rpi2 went 80 → 100 through paced, capped re-attestation
- [x] **C2: an ordinary RETRIEVE from `Csensor-001` (no special headers) → `Sui DAC consult` → `Sui GRANT`, on-chain digest, HTTP 200.** Repeated after every redeploy.
- [x] Proof scripts ported to v8 and re-run live: **10/10 pass** (see "2026-11-10 (later)" below)
- [x] **Failover:** parent stopped. Both followers detected the silence (17 s / 20 s), waited at `LEASE_VALID` for ~19.5 min with **zero** transactions, then made **2 claims in total**: rpi3 won, rpi2 aborted (code 3), one winner. The new parent published its PoA, cluster epoch 0 → 1. The old parent rejoined as a follower without claiming.
- [x] **Reboot test** on rpi2 (2026-11-10 23:04Z), with no human action afterwards. Both containers restarted on `:rpi2-v8`; config came from the durable mounts; `sui-das-provision.service` recreated the DAS **and the C2 DAC wiring** (all 201, `ri=/in-cse/Csui-dac-ae`) about 50 s after boot; the B6 epoch was **read back** from the durable store, not reset; the node rejoined as a follower of rpi3 and resumed gossiping at the normal rate.

### H. Rollback
`scripts/v8/04_cutover.sh rollback` restores the v7 config and host scripts, and either the stopped v7 containers or, since `cleanup` ran on 2026-11-10, a recreation of them from the `:rpiN-v7-final` snapshot images. The snapshots keep the v7 entrypoint, Cmd and Env. **The image path has not been exercised.** Rolling back also brings back the looping v7 broker mesh. The v7 package is still live on-chain; a fresh publish doesn't touch it.

### I. After this lands
- v9 compatible upgrade: quorum (limitation 2) plus the UpgradeCap moved to a multisig. **Also a v9 candidate:** bind the advertised PoA to the parent that set it, or clear it in `claim_parent` (finding F2 below)
- ~~Re-measure latency, gas and failover for the paper, on the real DAC path~~ done, see `evidence/V8_MEASUREMENTS.md`
- Per-originator on-chain identity (design decision for the paper)
- ~~**Decide how DENYs are handled** (F3 below)~~ done: DENYs cost no gas since 2026-11-10 (free pre-check, deployed); on-chain DENY batches are staged for v9. See "F3" at the end

---

## 2026-11-10 (later): proofs on v8, v7 cleanup, paper measurements

The full write-up, with every table, is in **`evidence/V8_MEASUREMENTS.md`**. The raw data and
exact commands are in `evidence/v8-measurements/`.

### Proofs ported and re-run live: 10/10 pass
- `proofs/lib_v8.sh` (new) is the single place that loads IDs (from `deploy/v8/env.v8.sh`, generated from `deployment.env`; nothing hard-coded). Node-signed calls run inside each node's container with its own key over SSH key auth (no more `sshpass`); publisher-signed calls run in WSL. Every transaction is appended to `proofs_v8.csv` with digest, outcome and net gas, and every proof ends with a `RESULT` line.
- Call shapes now match v8. The requester comes from `ctx`. The access chain is a real 5-command PTB with receipts threaded through. Proofs that depended on a removed attack now assert the attack is rejected: A4 (Sui refuses before execution), A6/A7 (`TypeMismatch`, `UnusedValueWithoutDrop`, `NonEntryFunctionInvoked`), A10, A12, A1/A2.
- 07 and 09 no longer touch production objects: 07 mints a dedicated proof token, and 09 grants, revokes and burns a throwaway AdminCap. (The v7 version of 09 revoked rpi2's real cap.)
- `run_all.sh` covers all 10 proofs, with `BATCH=1` for unattended runs. Bench scripts use key auth. `bench/provision_das.sh` refuses to run without `LEGACY_V7_PROVISION=1`, because it re-adds the `Csensor-001` static bypass.

### Two failover bugs found by the proofs, fixed and deployed (bundle `7fa41e66`, 107/107 tests)
| Problem (seen live) | Fix |
|---|---|
| **F1.** A node named parent on-chain other than through its own successful claim never started parent duties. Examples: a claim that landed while the client saw an error or timeout, or one signed outside the plugin. Its 60 s claim lease lapsed unanchored, and no node noticed, because the deposed parent's presence beats kept every watchdog quiet (proof 06 run 1). | Chain sync on **every** node every 15 s (one free read); duties start whenever the chain names this node (`shouldTakeUpParentDuties`, `ParentReconcileTest`, mutation-checked). Verified live: proof 06 runs 2 and 3. |
| **F2.** Followers kept the **deposed** parent's PoA. The on-chain PoA isn't bound to its setter, so it still holds the old URL until the new parent publishes. | Followers re-check the PoA on every sync and rewrite it when it changes (`poaNeedsUpdate`, mutation-checked). Verified live in the failover run. A contract-level fix is noted for v9. |

Deployed with `prepare` → `redeploy` (twice, `set -o pipefail`, exit 0); the running jar sha256 `7fa41e66…` was checked inside all three containers.

### v7 containers removed (`04_cutover.sh cleanup`)
`:rpiN-v7-final` images were confirmed present first. Each `om2m-v7-old` log had grown to **7.7–7.9 GB**, not the 2.6 GB recorded earlier, and rpi3's v7 broker log to 1.5 GB. Disk used before → after: rpi1 25,248 → 17,305 MB, rpi2 26,967 → 18,922 MB, rpi3 26,536 → 17,218 MB (**~8–9.3 GB freed per node**). Log: `evidence/v8-measurements/cleanup_v7.log`. `rollback` now has an image-based path (see H; not exercised).

### Paper measurements, on the real DAC path (ordinary oneM2M requests)
- **Latency** (n = 100 each, on rpi3, all HTTP 200, 201 on-chain GRANTs confirmed). DAC RETRIEVE p50/p95/p99 **1321 / 2130 / 2460 ms**; DAC UPDATE **1339 / 2344 / 2807 ms**; no-chain baseline RETRIEVE 4.1 / 6.8 / 8.6 ms and UPDATE 6.9 / 10.6 / 15.4 ms; DAS cache hit 3.6 / 7.5 / 8.4 ms. The chain is ~99 % of the cost; reads and writes cost the same.
- **Gas** (net, from the effects of 256 real transactions). GRANT **1.60 mSUI**; DENY 1.00 mSUI (paid); trust write 1.00; claim 1.00; lease renew 1.00; PoA 1.00. Every abort costs as much as a success.
- **Failover** (parent CSE stopped; no human action). Takeover **5.0 s after the lease expired**; total time = remaining lease (642 s in this run) + 5 s. 2 claims (1 winner, 1 abort 3) and ~4 mSUI for the whole failover. The new parent anchored and published its PoA within 5.3 s of winning; followers corrected their PoA; the old parent rejoined as a follower 34 s after restart. `04_cutover.sh verify` was clean afterwards.

### Open items from this run
- **F3: fixed, see the F3 section below.** (Was: DENYs are paid aborted transactions (~1 mSUI each, so a mapped originator can drain rpi3's gas), and they never reach the AuditTrail (`log_denied_authorized` needs the `AuditAdminCap`, which the publisher holds). Options are in `V8_MEASUREMENTS.md` §5.)
- **F4, for the paper.** "Every decision is audited" holds only for GRANTs. Every GRANT rewrites one shared ~9.7 KB trail object.
- **F7.** The image-based rollback after `cleanup` is written but not exercised.

### v9 prerequisite: type-origin package id for PoA reads (2026-11-10, deployed)
After a compatible upgrade, call targets move to the new package id but Move types keep the **original** (v8) id. `fetchParentPoa` spelled the dynamic-field key as `<sui.package.id>::failover::ParentPoaKey`, so pointing the plugin at v9 would have made every PoA read come back empty.
- New config key **`sui.package.original.id`** (type origin), defaulting to `sui.package.id`. It is used only for type names; every MoveCall still targets `sui.package.id`. The audit found no other plugin site that builds a package type string: the rest are call targets or framework types (`0x2::coin::Coin<0x2::sui::SUI>`).
- **v9 owner check.** `fetchParentPoa` also reads `<original>::failover::ParentPoaOwnerKey` and ignores a PoA whose owner is not `current_parent`. With no owner field (v8), behaviour is unchanged; I checked live that GraphQL returns a null field, not an error, for a type the v8 package doesn't define.
- `03_gen_config.sh` emits `sui.package.original.id=$PKG_V8`. When `sui.package.id` moves to v9, this key must stay at the v8 id. The generated files under `deploy/v8/` were regenerated (new key and stamp only). **The live nodes' config was not changed;** they rely on the default, which is the same value.
- Tests: `ParentPoaTypeOriginTest` (10, end-to-end against a local stub GraphQL endpoint that answers by exact type tag) and `PackageOriginalIdTest` (3). Six mutants were all killed. The full suite passes, **120/120**.
- Deployed with `prepare` → `redeploy` → `verify` (all exit 0); jar sha256 `3aec03c3…` confirmed inside all three containers. Behaviour on v8 is identical: rpi1 is parent and anchors its lease; all three nodes log `[fetchParentPoa] found under 0x88f0…` and hold the PoA `http://10.25.96.200:8282/`; the C2 GRANT went through on-chain (`9QKP2sX8…`).

### F3: DENYs cost no gas (2026-11-10, deployed, bundle `7e767ac5`)
**Problem (live).** Every DENY was a submitted PTB that aborted on-chain and still
paid about 1 mSUI. A sensor mapped to rpi3 could drain rpi3's gas by repeating a
forbidden request. The abort also rolled back any audit write.

**Fix in the plugin (v8, no contract change).**
- **Free pre-check.** `NativePtbBuilder.precheckThenSubmit` simulates the exact
  TransactionData that would be signed (GraphQL `simulateTransaction`,
  `checksEnabled:true`, same gas coin and object versions). Only a simulated
  success is signed and submitted.
  - A simulated abort returns DENY with nothing submitted.
  - No simulation result (transport, GraphQL or unknown status) fails closed:
    DENY, nothing submitted.
  - A stale-version refusal at the pre-check is still rebuilt by `withStaleRetry`.
  - A state change between simulation and execution can still yield a paid
    DENY, labelled `DENY_EXECUTED`.
- **`das/DenyGuard`.**
  - A 10 s LRU cache (1,024 keys) of verdict DENYs per originator, resource
    and op. A repeat inside the TTL is answered locally, with no network call.
  - A per-originator throttle: 30 verdict DENYs per 60 s window, then local
    DENYs until the window ends.
  - Only verdicts (`SIMULATED`, `CHAIN`) are cached or charged; transport
    errors never are.
  - Both maps are size-bounded.
- **`das/DenyLog`.**
  - Each DENY is one JSON line: ts, originator, address, resource, op, source,
    reason. It goes to `/var/lib/sui-om2m/deny-log.jsonl` (host
    `~/sui-runtime-config/state/`, durable), rotated at 5 MB with 3 kept.
  - A running SHA-256 per window, closed with a `{"batch":...}` marker. That
    digest is what v9 anchors on-chain (`V9_DESIGN.md` §2.9).
- **`das/DenyBatchFlusher`.** The v9 on-chain flush. It ships in this bundle
  but stays off (`sui.das.deny.audit.flush.enabled=false`) because the Move
  function exists only in v9.
- **Config keys** (`SuiConfig`, emitted by `03_gen_config.sh` and checked by
  its self-check):
  - `sui.das.precheck.enabled` (true)
  - `sui.das.deny.cache.ttl.ms` / `.max` (10000 / 1024)
  - `sui.das.deny.rate.max` / `.window.ms` (30 / 60000)
  - `sui.das.deny.log.path` / `.max.bytes` / `.keep`
  - `sui.das.deny.audit.flush.enabled` (false) / `.interval.min` (15, floored at 5)

**Tests: 153/153** (was 120), animal-sniffer clean. The 33 new tests:
`PrecheckGateTest` (10), `DenyGuardTest` (8), `DenyLogTest` (6),
`DenyBatchFlusherTest` (6), `DenyConfigDefaultsTest` (3). Eleven mutants were
all killed:
- a simulated DENY falling through to submit;
- a pre-check error treated as success;
- an unknown status accepted;
- `checksEnabled:false`;
- errors cached or charged;
- throttle removed;
- TTL ignored;
- digest without the newline;
- the flusher dropping on a transport error;
- the flusher never giving up;
- pre-check default off.

**Deployed.** `prepare` → `config` → `redeploy` → `verify`, all exit 0 with
`set -o pipefail`. The jar sha256 `7e767ac56a9665ed…` was confirmed inside all
three containers, and each logs `Sui DAS DENY handling: precheck=true …`.
`verify` was clean:
- rpi1 anchored its lease;
- gossip is v2 from all three nodes;
- the C2 RETRIEVE was granted on-chain (`GwMB3nFd…`).

**Live checks on rpi3** (`evidence/v8-measurements/f3-precheck/`):

| Check | Before (old bundle) | After |
|---|---|---|
| Forbidden DELETE by `Csensor-001` on `/in-cse/Csui-dac-ae` | HTTP 403; FAILURE tx `V77YmQFAqU7E…` (`evaluator::decide_and_log` aborted in `cap_token`, abort 4); rpi3 balance −1,013,441 MIST | HTTP 403; log `source=SIMULATED err=cap_token::E_OP_NOT_ALLOWED (abort 4)`; **no DAS transaction from rpi3**. Its only new transactions in the window were two `trust::increase_guarded` start-up re-attestations, and the balance fell by exactly their 2 × 1,000,600 MIST |
| Two immediate repeats | (each would have been another paid FAILURE) | HTTP 403 in 17 ms and 15 ms, `source=CACHED` |
| `deny-log.jsonl` | n/a | three lines (SIMULATED, CACHED, CACHED) with originator, address, resource, op 4 and reason |
| Ordinary RETRIEVE | GRANT on-chain | GRANT on-chain (`GwMB3nFd…`) |
| GRANT latency, n = 50 each (all HTTP 200; 101 distinct on-chain GRANT digests) | p50 1,320.7 / 1,339.3 ms (read / write, n = 100, measured earlier the same day) | p50 **1,550.8 / 1,553.8 ms**, p95 1,943.5 / 2,305.4 ms. The pre-check adds about **+230 / +214 ms** at the median, one simulation round trip. The baseline was also slightly slower in this run (5.7 vs 4.1 ms p50), so part of the gap is the network |

**v9 half (staged, not deployed): on-chain DENY batches.**
- `evaluator::log_deny_batch`, receipt-gated: IN/MN-CSE only, valid trust
  AdminCap, at most one batch per node per 5 min, no overlapping windows,
  32-byte digest.
- Implemented in `audit.move` as dynamic fields on the AuditTrail. It is a
  compatible upgrade, re-checked against b08b3e3.
- 17 new Move tests, **137/137**, and six guard mutants all killed. Details in
  `V9_DESIGN.md` §2.9, with the enablement step in its runbook, phase F.

**What stays true.** A DENY is still not on the per-decision audit ring. Until
v9 it is recorded only in the node's local log.
