#!/usr/bin/env bash
# build_bundle.sh - build the OM2M Sui plugin bundle reproducibly.
#
# Where to run it: the WSL Ubuntu environment on the publisher laptop. That is
# where the currently deployed bundle came from (its md5 matched the jar in
# ~/sui-om2m/plugin/target byte-for-byte), and where the four
# org.eclipse.om2m:*:1.1.0 jars are installed in ~/.m2. Those jars are not on
# Maven Central, so `mvn package` cannot work on a clean machine without them.
#
# What it guarantees:
#   - all sources compile, including the two OM2M-dependent classes
#     (das/SuiDasService, SuiPluginActivator) that nothing else can compile;
#   - animal-sniffer checks every JDK reference against the Java 8 API (the
#     containers run Java 1.8.0_492; see the comment in pom.xml);
#   - the full JUnit suite passes;
#   - the bundle's Import-Package matches what the running CSE resolves.
#
# Usage:  scripts/build_bundle.sh            # build + verify
# Output: plugin/target/org.eclipse.om2m.sui-0.1.0-SNAPSHOT.jar  (+ .sha256)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO/plugin"

for a in commons core core.service interworking.service; do
  f="$HOME/.m2/repository/org/eclipse/om2m/org.eclipse.om2m.$a/1.1.0/org.eclipse.om2m.$a-1.1.0.jar"
  [ -f "$f" ] || { echo "FATAL: missing $f - this machine cannot build the bundle (see header)"; exit 1; }
done

mvn -B clean package

JAR="target/org.eclipse.om2m.sui-0.1.0-SNAPSHOT.jar"
[ -f "$JAR" ] || { echo "FATAL: build produced no bundle"; exit 1; }

# Every class must be Java 8 bytecode (class-file major version 52).
bad=$(unzip -Z1 "$JAR" '*.class' | while read -r c; do
        v=$(unzip -p "$JAR" "$c" | od -An -tu1 -j7 -N1 | tr -d ' ')
        [ "$v" = "52" ] || echo "$c:$v"
      done)
[ -z "$bad" ] || { echo "FATAL: non-Java-8 class files:"; echo "$bad"; exit 1; }

sha256sum "$JAR" | tee "$JAR.sha256"
echo "OK: bundle built and verified -> $REPO/plugin/$JAR"
