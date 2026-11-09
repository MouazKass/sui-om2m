#!/usr/bin/env bash
#
# compile_plugin_offline.sh - type-check plugin/ against the REAL Eclipse OM2M
#                             sources, without Maven.
#
# Why this exists
# ---------------
# plugin/pom.xml depends on org.eclipse.om2m:*:1.1.0 with no <repositories>
# block. Those artifacts are NOT published to Maven Central, so a plain
# `mvn package` cannot resolve them - the local repository ends up holding only
# empty *.lastUpdated markers:
#
#   ~/.m2/repository/org/eclipse/om2m/org.eclipse.om2m.commons/1.1.0/
#       org.eclipse.om2m.commons-1.1.0.jar.lastUpdated      <- no .jar
#
# Every other dependency (jackson, osgi, paho, bouncycastle, commons-logging)
# does resolve from Central. So this script supplies the OM2M half from source,
# straight out of the upstream git repository, and runs javac.
#
# Note on the version string: upstream's Maven/OSGi version has been frozen at
# 1.1.0 since the 1.3.0 release. "1.1.0" is the bundle version shared by OM2M
# releases 1.3.0, 1.4.0, 1.4.1 and 1.5.0 - it is NOT an OM2M 1.1.0 release
# (no such tag exists). Checking out any of those tags gives version 1.1.0.
#
# Usage:  ./scripts/compile_plugin_offline.sh [om2m-git-ref]
#           default ref: 1.4.1
#
set -euo pipefail

REF="${1:-1.4.1}"
REPO="${OM2M_REPO:-https://gitlab.eclipse.org/eclipse/om2m/om2m.git}"
WORK="${WORK:-${TMPDIR:-/tmp}/om2m-offline-build}"
PLUGIN_SRC="$(cd "$(dirname "$0")/.." && pwd)/plugin/src/main/java"

SRC="$WORK/src"
JARS="$WORK/jars"
OUT="$WORK/classes"
CLONE="$WORK/om2m.git"

mkdir -p "$SRC" "$JARS" "$OUT"

# Windows/Git-Bash needs native paths for the JDK; elsewhere this is identity.
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
SEP=';'; command -v cygpath >/dev/null 2>&1 || SEP=':'

echo "==> 1. fetch OM2M sources (ref $REF)"
if [ ! -d "$CLONE" ]; then
  # --no-checkout: the upstream tree contains paths that fail to check out on
  # case-insensitive filesystems. We only ever read blobs via git archive.
  git clone --quiet --no-checkout "$REPO" "$CLONE"
fi
git -C "$CLONE" fetch --quiet --tags origin || true

# These four bundles are everything plugin/ compiles against.
# org.eclipse.om2m.commons has had TWO source roots since the 1.5.0 release:
# src/main/java and src-generated/main/java. AE, Container and
# AbstractFlexContainer moved into the latter; on 1.3.0-1.4.1 they are still in
# src/main/java. Discover the roots from the ref instead of hardcoding them, or
# a wrong guess produces a flood of "cannot find symbol".
mapfile -t MODULES < <(
  git -C "$CLONE" ls-tree -r --name-only "$REF"     | grep -oE '^(org\.eclipse\.om2m\.(commons|persistence\.service|interworking\.service|core\.service))/src[^/]*/main/java'     | sort -u
)
if [ "${#MODULES[@]}" -eq 0 ]; then
  echo "    ERROR: ref '$REF' has none of the expected OM2M bundles"; exit 1
fi
for m in "${MODULES[@]}"; do
  echo "    source root: $m"
  [ -d "$SRC/$m" ] || git -C "$CLONE" archive "$REF" "$m" | tar -x -C "$SRC"
done
echo "    $(find "$SRC" -name '*.java' | wc -l) OM2M source files"

echo "==> 2. collect third-party jars"
# OM2M targets Java 8; JAXB and JPA were removed from the JDK after 11, and
# javax.persistence ships inside commons/libs (not in git), so fetch both APIs.
fetch() { # url, filename
  [ -f "$JARS/$2" ] || curl -sSfL -o "$JARS/$2" "$1"
}
fetch "https://repo1.maven.org/maven2/javax/xml/bind/jaxb-api/2.3.1/jaxb-api-2.3.1.jar" jaxb-api.jar
fetch "https://repo1.maven.org/maven2/org/eclipse/persistence/javax.persistence/2.2.1/javax.persistence-2.2.1.jar" jpa-api.jar

CP=""
for d in com/fasterxml/jackson org/osgi org/eclipse/paho org/bouncycastle commons-logging; do
  if [ -d "$HOME/.m2/repository/$d" ]; then
    while IFS= read -r j; do CP="$CP$(winpath "$j")$SEP"; done \
      < <(find "$HOME/.m2/repository/$d" -name '*.jar' 2>/dev/null)
  fi
done
for j in "$JARS"/*.jar; do CP="$CP$(winpath "$j")$SEP"; done
if [ -z "${CP//[;:]/}" ]; then
  echo "    ERROR: no third-party jars found. Run 'mvn -f plugin/pom.xml dependency:resolve' once"
  echo "           (it will fail on the om2m artifacts, which is fine - the rest will download)."
  exit 1
fi

SP=""
for m in "${MODULES[@]}"; do SP="$SP$(winpath "$SRC/$m")$SEP"; done
SP="$SP$(winpath "$PLUGIN_SRC")$SEP"

echo "==> 3. javac"
# ISO-8859-1: some upstream generated files carry Latin-1 accented comments.
mapfile -t TARGETS < <(find "$PLUGIN_SRC" -name '*.java')
WIN_TARGETS=(); for t in "${TARGETS[@]}"; do WIN_TARGETS+=("$(winpath "$t")"); done

javac -nowarn -encoding ISO-8859-1 \
      -d "$(winpath "$OUT")" -cp "$CP" -sourcepath "$SP" \
      "${WIN_TARGETS[@]}"

echo
echo "==> OK. plugin/ type-checks against OM2M $REF."
echo "    classes in $OUT"
