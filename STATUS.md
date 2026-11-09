# Project Status — Blockchain-Enhanced oneM2M IoT Architecture

## On-chain (Sui testnet)
**Package:** `0xcba39e8bc98f6a7a40dc67aef7f150294b8a88fc5c72026fd8ed421b94419360`
Eight Move modules deployed: cap_token, identity, trust, policy, audit, evaluator, evolution, failover.

**Shared object registries (all live, version-tracked):**
- IDENTITY_REG `0x7cce2b...460375`
- TRUST_REG `0xce9bb8...befef0f`
- POLICY_REG `0x621e7f...5a77c`
- AUDIT_TRAIL `0x433a99...0db32f`
- CLUSTER (EE_5) `0x2ca259...a3800`

**Demo digests verified end-to-end on testnet:**
- 6-step PTB GRANT: `2dza2i7zFJw4BQVsLfP6SAyackyi4VHn7hwdCATWhZN2`
- 6-step PTB DENY/atomic rollback: `Dwp1DPrNC7UNRpvZPxuGwrqq9nneXGb3CxPYZCuafbxK`
- Layer 3 evolve: `AuEA82iMwhM5WpYcxBCqh5XvjLPZuuzW4fFKKctfLj6x`
- Failover takeover SUCCESS: `BCWavwY2yproEMHfFQLAwhP81b5orXA4fJvd11AYBYqv`

## Testbed (3-Pi physical deployment)
| Pi | Container | Sui Address | On-chain role | Trust | DAS |
|---|---|---|---|---|---|
| rpi1 (10.25.96.200) | om2m-in-cse | 0xef9c6271...d5f9 | 1 (IN-CSE) | 80 | ✅ active |
| rpi2 (10.25.96.201) | om2m-mn-cse-1 | 0x4be6060a...c1f5 | 2 (MN-CSE) | 70 | ✅ active |
| rpi3 (10.25.96.203) | om2m-mn-cse-2 | 0x27dacda1...ea10 | 2 (MN-CSE) | 70 | ✅ active |

Sui CLI installed on every Pi host (testnet-v1.73.0 aarch64).

## Architecture decision: standards-conformant DAS
After ruling out (a) modifying OM2M `Controller.doRequest` (hack) and (b) putting a reverse proxy in front of OM2M (parallel architecture, breaks oneM2M conformance), we use OM2M's **own dynamic-authorization extension point** (TS-0003). Our `SuiDasService` implements `org.eclipse.om2m.interworking.service.InterworkingService`. The CSE consults it through the standard NOTIFY-based DAS protocol; on PTB success the DAS returns granted `SetOfAcrs`, on PTB abort `ACCESS_DENIED`. **No OM2M core modification.**

Deployed on every CSE (Option B) rather than centralized on IN-CSE only (Option A), to preserve the decentralization story and make the trust-gated failover meaningful.

## What works right now
- All three CSEs bring up the DAS at startup:
[sui] Starting Sui Access Control plugin (DAS mode)
IPE service discovered: sui-das
[sui] DAS registered at APOC path: sui-das
Failover disabled: no cluster ID in sui.properties
[sui] Plugin ready. nodeAddress=<per-Pi-address> env=testnet
- OM2M itself confirms registration ("IPE service discovered") — the CSE knows there is an authorization authority at PoA `sui-das`.

## What's left to fire a real request end-to-end
1. **Install Sui CLI inside each container** (PtbBuilder shells out via `Runtime.exec`; CLI is currently only on the Pi hosts, not in the OM2M containers). ~10 min per Pi.
2. **Provision a DAC + ACP + test container** on at least one CSE via curl primitives.
3. **Provision originator→Sui address + token mappings** in the DAS (via `SuiConfig.registerAddress` / `registerToken`).
4. **Mint a test capability token on-chain** for the originator under the test resource.
5. **Fire a RETRIEVE** from curl and verify the chain: HTTP → CSE → NOTIFY → `SuiDasService.doExecute` → `PtbBuilder.evaluate` → Sui PTB → AccessLogged event → standard `DynAuthDasResponse` back to CSE → HTTP response.

Re-enable failover (`sui.failover.cluster.id=0x2ca259...a3800`) once Sui CLI is inside the container.

## Build artifacts
- Plugin source: 8 Move modules + Java classes for SuiPluginActivator, SuiConfig (with addr/token in-memory provisioning maps + register/resolve methods), SuiCli, PtbBuilder, SuiDasService (replaces deleted AccessControlProxy), FailoverManager.
- POM uses commons-logging (not slf4j; not exposed by OM2M's Equinox).
- Bundle target: Java 1.8 (Equinox EE filter); imports exclude `java.*`, `org.eclipse.paho.*`, `com.fasterxml.jackson.*` (embedded), no DS components (programmatic registration only).
- JAR: ~2.3 MB at `~/plugin/target/org.eclipse.om2m.sui-0.1.0-SNAPSHOT.jar` on rpi1.

## Open items
- **Trust scoring engine implementation** — friend's lane (proposal v2 approved by Dr. Gharib).
- **Performance benchmarks** (slide 11): latency, gas, throughput. ~1 hr against testnet.
- **IEEE journal write-up** (slide 12) — depends on benchmarks + trust engine + end-to-end demo.

## Action item before next session
Email Dr. Gharib a one-line confirmation: *"For decentralization fidelity, I'm deploying the Sui DAS on every CSE (IN + each MN) rather than centralized on the IN-CSE. Each CSE independently consults the same on-chain registries via the standard oneM2M dynamic-authorization interface (TS-0003). Sound right?"*

---

## Security batch A1-A12 / B1-B12 / C1-C6 — branch `security-fixes-v8` (2026-11-09)

Full evidence: `SECBATCH-2026-11_EVIDENCE.md`.

### State

Code complete and source-verified on branch `security-fixes-v8`; **not
committed and not deployed**. 32 tracked files changed plus 8 new files
(3 Move test modules, 3 Java trust classes, 2 Java test classes) and 2 removals
(`move/sources/evolution.move.bak`, plus the A11 deletions inside
`evolution.move`).

What it changes, in one line each:

- **Move A1-A12** — AdminCap validity now enforced on `add_node`, the bootstrap
  path and both grant paths, fail-closed from genesis; the 6-step access
  decision became an unforgeable "hot potato" receipt chain
  (identity -> trust -> cap_token -> policy -> evaluator) with every forgeable
  parameter *deleted* rather than validated; audit writes are `public(package)`;
  failover leases bounded at 1 h in both writers; trust-score writes bounded at
  delta 15 / 60 s; dead `SubCapability` state removed.
- **Java B1-B12** — unsigned gossip rejected; forgery charged to the real
  signer; median + Byzantine-bounded agreement threshold; self-observations
  excluded; non-submitters read real on-chain state instead of stamping their
  own estimate; replay ordinal became `(epoch, timestamp)` so a
  clock-regressed node is no longer locked out for good (wire v1 -> v2);
  heartbeat recorded for every node, not only the parent, with tier hysteresis;
  observers must be registered on chain; 8 signals summing to 100 replacing 10
  with two dead and two double-counted.
- **Scripts/config C1/C3/C6** — proof and bench labels corrected from "read" to
  write authorization (CREATE) with the op *value* deliberately unchanged;
  `env.sh`'s stale "v6 is an upgrade of v1" comments corrected; annotated
  `config/sui.mappings.properties` added with colons escaped.

### Verified results (reproduced here, 2026-11-09)

- `sui move build` (sui 1.83.1) — **exit 0, 0 errors**. 6 warnings, all
  pre-existing `deprecated usage` of `sui::dynamic_field::exists_` in
  trust.move's TR7 block; not introduced by this batch.
- `sui move test` — **OK. Total tests: 66; passed: 66; failed: 0.**
  (20 evolution, 13 receipt chain, 9 admin-cap validity, 9 failover lease,
  8 trust revocation, 7 policy.)
- Java, JDK 21 — 24 of 26 main sources compile clean (`javac` exit 0);
  all 4 JUnit classes run **OK (33 tests)**: 14 aggregation, 10 replay,
  6 membership, 3 failover gas.
- Not compiled here: `das/SuiDasService.java`, `SuiPluginActivator.java` —
  unresolvable `org.eclipse.om2m.*` / `org.osgi.framework` imports (those jars
  are not in Maven Central). Environment limitation, not a code defect, but the
  B12 two-line change in `SuiDasService.java` is consequently **unverified**.
- OSGi bundle packaging (`maven-bundle-plugin`) was never exercised.

### PENDING — requires manual action

**v8 fresh publish pending — requires manual `sui client publish` + wallet
signing, re-registration of all nodes/caps/tokens, and env.sh/sui.properties
updates on every Pi. Not performed by this batch.**

Two things to read before doing it, both in `RECOVERY.md`:

1. "v8 fresh publish — EVERY object id is invalidated" — a fresh publish means a
   new type root, so no v6/v7 registry, cap or CapToken is accepted by v8.
2. "v8 DEPLOYMENT-MODEL CHANGE: each CSE must sign its own access PTB" — the
   requester is now derived from the transaction signer, so proxy-signing on
   behalf of a node aborts with `identity::E_NOT_REGISTERED` (1) or
   `cap_token::E_NOT_TOKEN_OWNER` (5). Both surface as "Access PTB aborted"
   with no digest, i.e. indistinguishable from a policy denial unless you check
   the abort module and code.

Also still open: the seven source-level findings listed at the end of
`SECBATCH-2026-11_EVIDENCE.md` (chiefly the unimplemented `audit::resize` shrink
path, and the stale pre-v8 compiled snapshot in `move/build/`), and the
external-NOTIFY / ACP consultation blocker already tracked in `RECOVERY.md`,
which this batch did not touch.
