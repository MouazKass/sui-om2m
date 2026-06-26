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
