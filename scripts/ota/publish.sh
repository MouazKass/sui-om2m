#!/usr/bin/env bash
# publish.sh - release a firmware image to every ESP32 sensor, over the air.
#
#   scripts/ota/publish.sh <image.bin> <version> [target]     (Git Bash)
#   scripts/ota/publish.sh --withdraw                          (stop offering a release; deletes
#                                                               the images, which hold the Wi-Fi credentials)
#
#   image.bin  the APP image from esp32/firmware/build_in_docker.sh
#              (build/esp32_sensor_node.ino.bin, NOT the merged .bin)
#   version    integer, strictly greater than every earlier release (the boards
#              refuse anything not newer: anti-rollback)
#   target     "all" (default) or one DEVICE_ID
#
# Steps: build the manifest body (esp32/pi/ota_manifest.py, the reference
# format) -> sign it IN WSL with ~/.sui-om2m-fw/fw_signing.pem (openssl, the key
# never leaves WSL) -> refuse unless the signing key is pinned in
# deploy/v9/fw_keys/ -> copy image + manifest to /var/lib/om2m-ota/fw on every
# active node (deploy/inventory.tsv) -> verify each node serves exactly what was
# signed (ota_manifest.py check, the boards' own acceptance logic) -> publish
# the retained announce om2m/ota/manifest on every node's broker.
# DRY_RUN=1 stops after signing and the local check.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/inventory.sh"
inv_load
SSH=(ssh -F "$INV_SSH_CONFIG" -o ConnectTimeout=10)
SCP=(scp -q -F "$INV_SSH_CONFIG" -o ConnectTimeout=10)
PY=$(command -v python || command -v python3)
OM_PY=$REPO/esp32/pi/ota_manifest.py
command -v cygpath >/dev/null 2>&1 && OM_PY=$(cygpath -w "$OM_PY")   # Windows python under Git Bash
REL=/var/lib/om2m-ota/fw
TOPIC=om2m/ota/manifest

if [[ ${1:-} == --withdraw ]]; then
  for n in $(inv_nodes active); do
    "${SSH[@]}" "$n" "rm -f $REL/manifest.json $REL/*.bin $REL/.*.tmp; docker exec mosquitto mosquitto_pub -r -q 1 -t $TOPIC -n" \
      && echo "$n: withdrawn"
  done
  exit 0
fi

BIN=${1:?usage: publish.sh <image.bin> <version> [target]}
VER=${2:?version}
TARGET=${3:-all}
[[ -f $BIN ]] || { echo "no such file: $BIN"; exit 1; }
[[ $VER =~ ^[1-9][0-9]{0,8}$ ]] || { echo "version must be a positive integer"; exit 1; }
[[ $TARGET == all || $TARGET =~ ^[a-z0-9-]{1,40}$ ]] || { echo "bad target"; exit 1; }
case "$BIN" in *merged*) echo "use the app image (esp32_sensor_node.ino.bin), not the merged flash image"; exit 1;; esac
SIZE=$(wc -c < "$BIN" | tr -d ' ')
SHA=$(sha256sum "$BIN" | cut -d' ' -f1)
(( SIZE <= 0x140000 )) || { echo "image ($SIZE bytes) does not fit one OTA slot (1310720)"; exit 1; }
[[ $(head -c1 "$BIN" | od -An -tx1 | tr -d ' ') == e9 ]] || { echo "not an ESP32 app image (no 0xE9 magic)"; exit 1; }
NAME=fw-$VER.bin
TS=$(date +%s)

# ---- sign in WSL (the private key never leaves it) --------------------------
SIGN='set -euo pipefail
k=$HOME/.sui-om2m-fw/fw_signing.pem
[ -r "$k" ] || { echo "no signing key: run scripts/ota/keygen.sh" >&2; exit 1; }
pub=$(openssl pkey -in "$k" -pubout -outform DER | tail -c 32 | od -An -tx1 | tr -d " \n")
t=$(mktemp -d); trap "rm -rf $t" EXIT
{ printf "om2m-esp32-fw-v1\0"; printf "%s" "$body_b64" | base64 -d; } > "$t/msg"
openssl pkeyutl -sign -inkey "$k" -rawin -in "$t/msg" -out "$t/sig"
echo "$pub $(od -An -tx1 "$t/sig" | tr -d " \n")"'
# Scripts reach WSL on stdin (bash -s): wsl.exe mangles quoting in -c arguments.
run_wsl() {
  if command -v wsl.exe >/dev/null 2>&1; then printf '%s\n' "$1" | wsl.exe -d Ubuntu -- bash -s | tr -d '\r'
  else printf '%s\n' "$1" | bash -s; fi
}
PUB=$(run_wsl 'openssl pkey -in $HOME/.sui-om2m-fw/fw_signing.pem -pubout -outform DER | tail -c 32 | od -An -tx1 | tr -d " \n"')
[[ $PUB =~ ^[0-9a-f]{64}$ ]] || { echo "cannot read the signing key in WSL (run scripts/ota/keygen.sh)"; exit 1; }
grep -qx "$PUB" "$REPO"/deploy/v9/fw_keys/*.pub 2>/dev/null \
  || { echo "signing key $PUB is not pinned in deploy/v9/fw_keys/: boards would refuse it"; exit 1; }
# MSYS_NO_PATHCONV: Git Bash would turn "/fw/..." into a Windows path for a Windows python
BODY=$(MSYS_NO_PATHCONV=1 "$PY" "$OM_PY" body "$VER" "$SIZE" "$SHA" "/fw/$NAME" "$PUB" "$TARGET" "$TS")
[[ $BODY == *"\"path\":\"/fw/$NAME\""* ]] || { echo "manifest body has a wrong path: $BODY"; exit 1; }
B64=$(printf '%s' "$BODY" | base64 -w0)          # only [A-Za-z0-9+/=]: safe to embed
read -r SPUB SIG < <(run_wsl "body_b64=$B64
$SIGN")
[[ $SPUB == "$PUB" && $SIG =~ ^[0-9a-f]{128}$ ]] || { echo "signing failed"; exit 1; }
MANIFEST="${BODY%\}},\"sig\":\"$SIG\"}"
(( ${#MANIFEST} < 500 )) || { echo "manifest too long for the board's MQTT buffer (${#MANIFEST})"; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
printf '%s' "$MANIFEST" > "$WORK/manifest.json"
echo "release v$VER for '$TARGET': $SIZE bytes sha256 $SHA"
echo "manifest: $MANIFEST"
[[ ${DRY_RUN:-0} == 1 ]] && { echo "DRY_RUN: not published"; exit 0; }

# ---- distribute + verify on every node ---------------------------------------
NODES=$(inv_nodes active)
CHECK_DEV=$([[ $TARGET == all ]] && echo ota-verify || echo "$TARGET")
for n in $NODES; do
  "${SCP[@]}" "$BIN" "$n:$REL/.$NAME.tmp"
  "${SCP[@]}" "$WORK/manifest.json" "$n:$REL/.manifest.json.tmp"
  "${SSH[@]}" "$n" "mv -f $REL/.$NAME.tmp $REL/$NAME && mv -f $REL/.manifest.json.tmp $REL/manifest.json"
  "${SCP[@]}" "$REPO/esp32/pi/ota_manifest.py" "$REPO/deploy/v9/fw_keys/trusted.txt" "$n:/tmp/"
  out=$("${SSH[@]}" "$n" "python3 /tmp/ota_manifest.py check 127.0.0.1 8070 $CHECK_DEV 0 /tmp/trusted.txt; rc=\$?; rm -f /tmp/ota_manifest.py /tmp/trusted.txt; exit \$rc") \
    || { echo "$n: serves a release the boards would REFUSE: $out"; exit 1; }
  echo "$n: serving v$VER ($out)"
done
for n in $NODES; do
  printf '%s' "$MANIFEST" | "${SSH[@]}" "$n" "docker exec -i mosquitto mosquitto_pub -r -q 1 -t $TOPIC -s"
  echo "$n: announced on $TOPIC (retained)"
done
echo "done: release v$VER published to $(echo $NODES | wc -w) node(s)"
