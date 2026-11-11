#!/usr/bin/env bash
# build_in_docker.sh - compile the real ESP32 firmware (with the pinned bridge
# ack keys from ack_keys.h) in a throwaway container on a build host (rpi1 by
# default), and bring the .bin files back to esp32/firmware/build/.
#
#   esp32/firmware/build_in_docker.sh            # build on rpi1
#   BUILD_HOST=rpi3 esp32/firmware/build_in_docker.sh
#
# Pinned toolchain: arduino-cli, the esp32 Arduino core and the three
# libraries below at fixed versions, so a rebuild is reproducible. The
# container, its image layers and the temporary folder are removed afterwards.
set -euo pipefail
HOST=${BUILD_HOST:-rpi1}
ARDUINO_CLI_VERSION=${ARDUINO_CLI_VERSION:-1.1.1}
ESP32_CORE=${ESP32_CORE:-3.2.0}         # 3.0.7 fails to link: its libsodium lacks the AEGIS symbols sodium_init needs
FQBN=${FQBN:-esp32:esp32:esp32}          # "ESP32 Dev Module"
LIBS=${LIBS:-"PubSubClient@2.8;DHT sensor library@1.4.6;Adafruit Unified Sensor@1.1.14"}   # ;-separated

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SKETCH=$REPO/esp32/firmware/esp32_sensor_node
OUT=$REPO/esp32/firmware/build
grep -q '^#define ACK_TRUSTED_KEYS "' "$SKETCH/ack_keys.h" \
  || { echo "ack_keys.h has no pinned keys: run esp32/firmware/gen_ack_keys.sh"; exit 1; }

TMP=/tmp/esp32-fw-build-$$
trap 'ssh "$HOST" "rm -rf $TMP" || true' EXIT
echo "== copying sketch to $HOST:$TMP"
ssh "$HOST" "mkdir -p $TMP/esp32_sensor_node $TMP/out"
tar -C "$SKETCH" -cf - . | ssh "$HOST" "tar -C $TMP/esp32_sensor_node -xf -"

echo "== building in a throwaway container (core esp32@$ESP32_CORE, fqbn $FQBN)"
ssh "$HOST" "docker run --rm -e LIBS='$LIBS' \
  -e CLI_V=$ARDUINO_CLI_VERSION -e CORE=$ESP32_CORE -e FQBN=$FQBN \
  -v $TMP/esp32_sensor_node:/src/esp32_sensor_node:ro -v $TMP/out:/out \
  debian:bookworm-slim bash -euo pipefail -c '
    apt-get update -qq >/dev/null && apt-get install -y -qq curl ca-certificates python3 python3-serial >/dev/null
    arch=\$(uname -m); case \$arch in aarch64) a=ARM64;; x86_64) a=64bit;; *) echo unsupported \$arch; exit 1;; esac
    curl -fsSL https://github.com/arduino/arduino-cli/releases/download/v\$CLI_V/arduino-cli_\${CLI_V}_Linux_\$a.tar.gz | tar -xz -C /usr/local/bin arduino-cli
    arduino-cli version
    arduino-cli config init >/dev/null
    arduino-cli config set board_manager.additional_urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
    arduino-cli core update-index >/dev/null
    arduino-cli core install esp32:esp32@\$CORE >/dev/null
    IFS=\";\" read -ra L <<< \"\$LIBS\"; for l in \"\${L[@]}\"; do arduino-cli lib install \"\$l\" >/dev/null; done
    arduino-cli core list; arduino-cli lib list
    cp -r /src/esp32_sensor_node /tmp/esp32_sensor_node
    arduino-cli compile --fqbn \$FQBN --warnings default --output-dir /out /tmp/esp32_sensor_node 2>&1 | tail -25
    cd /out && sha256sum *.bin > SHA256SUMS && ls -l
  '" 2>&1 | tee "$REPO/esp32/firmware/build.log.tmp"

mkdir -p "$OUT"
ssh "$HOST" "tar -C $TMP/out -cf - ." | tar -C "$OUT" -xf -
ssh "$HOST" "rm -rf $TMP; docker rmi -f debian:bookworm-slim >/dev/null 2>&1 || true"
mv "$REPO/esp32/firmware/build.log.tmp" "$OUT/build.log"
echo "== done: $OUT"
ls -l "$OUT"
