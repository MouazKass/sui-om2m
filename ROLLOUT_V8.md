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
- [ ] Proof scripts re-run against v8 (they still reference `$PKG_V7` at ~20 sites)
- [x] **Failover:** parent stopped. Both followers detected the silence (17 s / 20 s), waited at `LEASE_VALID` for ~19.5 min with **zero** transactions, then made **2 claims in total**: rpi3 won, rpi2 aborted (code 3), one winner. The new parent published its PoA, cluster epoch 0 → 1. The old parent rejoined as a follower without claiming.
- [x] **Reboot test** on rpi2 (2026-11-10 23:04Z), with no human action afterwards. Both containers restarted on `:rpi2-v8`; config came from the durable mounts; `sui-das-provision.service` recreated the DAS **and the C2 DAC wiring** (all 201, `ri=/in-cse/Csui-dac-ae`) about 50 s after boot; the B6 epoch was **read back** from the durable store, not reset; the node rejoined as a follower of rpi3 and resumed gossiping at the normal rate.

### H. Rollback
`scripts/v8/04_cutover.sh rollback`: restores the v7 containers, config and host scripts. The `:rpiN-v7-final` images stay available even after `cleanup`. The v7 package is still live on-chain; a fresh publish doesn't touch it.

### I. After this lands
- v9 compatible upgrade: quorum (limitation 2) plus the UpgradeCap moved to a multisig
- Re-measure latency, gas and failover for the paper, on the real DAC path
- Per-originator on-chain identity (design decision for the paper)
