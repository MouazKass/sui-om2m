# Running the test suites

## Move-layer unit tests (24 tests)
Cover EVO5/cap-token (17), policy PO1/PO2 (5), TR7 cap revocation (2).
    cd move && sui move test
Runs offline on any machine with the sui CLI. All 24 pass.

## Java-layer unit tests (7 tests)
Cover FM5 gas-exhaustion detection (3) and SY5 replay rejection (4).
    cd plugin && mvn test                 # run on a Pi node (e.g. ~/plugin)
Build on a Raspberry Pi node: it has Maven, the right JDK, and the OM2M
1.1.0 bundle jars in its local repo. The laptop tree does not compile
standalone (missing slf4j / OM2M deps, newer-JDK source features); the Pi
~/plugin is the canonical buildable tree. All 7 pass there.

To build on a fresh machine, install the 4 OM2M bundle jars into the local
Maven repo with a parentless POM:
    mvn install:install-file -Dfile=<om2m.commons jar> -DpomFile=<flat pom>
(repeat for core, core.service, interworking.service), then `mvn test`.

NOTE: the laptop ~/sui-om2m/plugin and Pi ~/plugin have drifted; reconciling
them (make the Pi tree a clone of the repo) is tracked as git-hygiene.

---

## UPDATE 2026-11-09 — security-fixes-v8 test inventory

Counts below were observed by running the suites, not estimated.

### Move-layer unit tests (66 tests, all passing)

    cd move && sui move test
    # Test result: OK. Total tests: 66; passed: 66; failed: 0

Runs fully offline on any machine with the sui CLI (verified with sui 1.83.1).
Per module, as counted in `move/tests/`:

| Module | Tests | Covers |
|---|---|---|
| `evolution_lifecycle_tests.move` | 20 | A9 signer-derived evolve, 9 tier-mapping cases, cap_token validate/revoke |
| `receipt_chain_tests.move` | 13 | A3 identity, A4 token ownership, A5 registry-read trust, A6 chain binding, A7 authorized deny-log |
| `admin_cap_validity_tests.move` | 9 | A1 add_node, A2 re-bootstrap, A8 unified mint path |
| `failover_lease_tests.move` | 9 | A10 lease bound in BOTH create_cluster and renew_lease |
| `trust_revocation_tests.move` | 8 | A12 delta/rate limits, TR7 revocation, self-scoring |
| `policy_tests.move` | 7 | PO1 deny-by-default, PO2 three conditions + boundaries |

`sui move build` is exit 0 with 6 warnings, all pre-existing
`WC04037 deprecated usage` on `sui::dynamic_field::exists_` in trust.move's TR7
block. They are not introduced by this batch.

### Java-layer unit tests (33 tests, all passing)

| Class | Tests | Covers |
|---|---|---|
| `trust/TrustAggregationTest` | 14 | B3 median + k=floor((n-1)/2)+1 threshold, B9 tier hysteresis, B11/B12 8-signal weights |
| `trust/TrustGossipReplayTest` | 10 | B6 `(epoch, producedAtMs)` ordinal, v1 wire rejection |
| `trust/TrustGossipMembershipTest` | 6 | B10 registered-observer admission, denominator stuffing, fail-closed registry |
| `failover/FailoverManagerGasTest` | 3 | FM5 gas-exhaustion detection |

Canonical command, on a tree that has the OM2M jars:

    cd plugin && mvn test

**Caveat — the full plugin is not Maven-resolvable on a bare machine.** The four
`org.eclipse.om2m:*:1.1.0` bundle jars (commons, core, core.service,
interworking.service) are not in Maven Central, so `mvn test` only works where
they are installed in the local `~/.m2`:

    mvn install:install-file -Dfile=<om2m.commons jar> -DpomFile=<flat parentless pom>
    # repeat for core, core.service, interworking.service

A Raspberry Pi node's `~/plugin` has them and is the canonical buildable tree.

Without those jars you can still compile and run everything except
`das/SuiDasService.java` and `SuiPluginActivator.java`, which are the only two
files that import OM2M/OSGi types. 24 of the 26 main sources plus all 4 test
classes compile and the 33 tests pass that way — `javac -d <out> -cp <junit,
hamcrest, jackson, paho, bcprov, commons-logging>` over the source list minus
those two files, then
`java -cp <jars>;<out> org.junit.runner.JUnitCore <the 4 test classes>`.
Verified on JDK 21; useful for checking the trust/failover/sdk/ptb/config
layers, but note it does NOT cover the DAS entry point or OSGi packaging.
