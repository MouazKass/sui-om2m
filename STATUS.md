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
