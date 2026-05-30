# sui-om2m — Blockchain-Enhanced oneM2M Access Control

Implementation companion to the AUS × Sui presentation
*Blockchain-Enhanced oneM2M IoT Architecture: Integrating Sui
Blockchain for Trustworthy IoT Interoperability* (Mouaz Kassoumeh,
Hamza AlCharif; supervisors Dr. Anastassia Gharib, Eng. Wissam Abou
Khreibe).

This repository contains the Move smart contracts and the Java OM2M
plugin that realise the three-layer Sui-native access control
framework (slides 7–9) and the trust-gated parent failover mechanism
(slide 10).

## Layout

```
sui-om2m/
├── move/                       Sui Move package
│   ├── Move.toml
│   └── sources/
│       ├── cap_token.move      Layer 1: Object-Owned Capability Tokens
│       ├── identity.move       PTB step 1: Identity
│       ├── trust.move          PTB step 2: Trust Score
│       ├── policy.move         PTB step 4: Policy
│       ├── audit.move          PTB step 6: Audit Log
│       ├── evaluator.move      PTB step 5 + step 6 orchestration
│       ├── evolution.move      Layer 3: Self-Evolving Living Tokens
│       └── failover.move       Trust-Gated Parent Failover (secondary)
├── plugin/                     Java OSGi bundle, drops into OM2M CSE
│   ├── pom.xml
│   └── src/main/java/org/eclipse/om2m/sui/
│       ├── SuiPluginActivator.java
│       ├── config/SuiConfig.java
│       ├── sdk/SuiCli.java                Shell-out wrapper
│       ├── ptb/PtbBuilder.java            Builds the atomic 6-call PTB
│       ├── proxy/AccessControlProxy.java  Intercepts CSE requests
│       └── failover/FailoverManager.java  MQTT + on-chain claim path
├── config/sui.properties.sample
└── scripts/
    ├── deploy_sui_package.sh   Publishes the Move package
    └── bootstrap_testbed.sh    Seeds identity, trust, policy, tokens
```

## Slide → Code Map

| Slide / Element                          | Code                                                    |
|------------------------------------------|---------------------------------------------------------|
| 8 — Layer 1 (Capability Tokens)          | `cap_token.move`                                        |
| 8 — Layer 2 (Atomic 6-Step PTB)          | `PtbBuilder.java::evaluate`                             |
| 8 — Layer 3 (Self-Evolving Tokens)       | `evolution.move`                                        |
| 9 — Step 1 Identity                      | `identity::verify`                                      |
| 9 — Step 2 Trust Score                   | `trust::require_min`                                    |
| 9 — Step 3 Token                         | `cap_token::validate_for_use`                           |
| 9 — Step 4 Policy                        | `policy::evaluate`                                      |
| 9 — Step 5 Decision (implicit)           | reaching `evaluator::decide_and_log` = grant            |
| 9 — Step 6 Audit Log                     | `evaluator::decide_and_log` → `audit::log`              |
| 9 — Access Control Proxy box             | `AccessControlProxy.java`                               |
| 9 — Result returned to OM2M node         | `AccessControlProxy::intercept` return value            |
| 10 — Off-chain MQTT heartbeat            | `FailoverManager::startParentDuties`                    |
| 10 — Watchdog / Failure Suspected        | `FailoverManager::watchdogTick`                         |
| 10 — Trust Gate                          | `failover::claim_parent` (checks identity + trust)      |
| 10 — Multiple Claims / Sui TX Ordering   | Sui consensus on `claim_parent` PTB                     |
| 10 — New Parent Elected                  | `failover::claim_parent` state update + `ParentChanged` |
| 10 — Resume MQTT                         | `FailoverManager::startParentDuties` after claim        |

The three-layer framework runs on every access request. The failover
mechanism is a separate, parallel system — it only activates when a
parent node's MQTT heartbeats stop.

## Deployment Workflow

Pre-reqs on every Raspberry Pi:
- `sui` CLI installed and configured: `sui client active-env` →
  `testnet`, `sui client active-address` has testnet SUI gas.
- Java 11 + Maven on the build host.
- OM2M already deployed (matching the existing `mouazkass/om2m-in-cse-fixed`
  and `mouazkass/om2m-mn-cse-configured` Docker images).
- Mosquitto MQTT broker reachable at `tcp://10.25.96.200:1883`.

Step 1 — Publish the package on one node (typically the IN-CSE at
10.25.96.200):

```bash
cd sui-om2m
./scripts/deploy_sui_package.sh
```

The script outputs the package ID and all shared-object IDs to paste
into `sui.properties`.

Step 2 — Create the failover cluster:

```bash
sui client call \
  --package $PKG --module failover --function create_cluster \
  --args '[69,69,95,53]' <in_cse_addr> 50 60000 0x6 \
  --gas-budget 20000000
```

The `[69,69,95,53]` is `"EE_5"` as a vector of bytes — matches the
cluster naming from Hammad et al.'s prior work.

Step 3 — Seed identity, trust, and a sample policy:

```bash
./scripts/bootstrap_testbed.sh
```

Step 4 — Build the plugin bundle:

```bash
cd plugin
mvn clean package
```

Step 5 — Copy the bundle to each Pi's `$OM2M_HOME/plugins/`,
copy `config/sui.properties.sample` to
`$OM2M_HOME/configuration/sui.properties` (one per node, with that
node's address filled in), and restart the CSE.

## Sui-Exclusive Features Used (from slide 7)

| Feature                       | Module                  | Why it's Sui-only          |
|-------------------------------|-------------------------|----------------------------|
| Object-Centric Model          | `cap_token.move`        | tokens as standalone objs  |
| Programmable Transaction Blks | `PtbBuilder.java`       | atomic 6-call composition  |
| Dynamic Fields                | `evolution.move`        | runtime tier mutation      |
| Transfer-to-Object            | `evolution.move`        | sub-cap attached to token  |
| Move linear types (shared w/ Aptos but combined w/ above is unique) | `cap_token.move` | `key + store` only, no `copy`, no `drop` |
