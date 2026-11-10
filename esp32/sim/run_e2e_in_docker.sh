#!/usr/bin/env bash
# run_e2e_in_docker.sh - run every offline ESP32-layer test (esp32/run_all_tests.sh)
# inside a throwaway container, so nothing (g++, mosquitto, flask) is installed on a host.
#
#   esp32/sim/run_e2e_in_docker.sh              # on rpi1 over ssh (default)
#   E2E_HOST=local esp32/sim/run_e2e_in_docker.sh   # on this machine's docker
#   E2E_HOST=rpi3  esp32/sim/run_e2e_in_docker.sh   # any ssh alias with docker
#
# What it does:
#   1. copies esp32/ to a temp dir on the docker host
#   2. builds a temporary image (debian + g++ + mosquitto + pinned python deps)
#   3. runs the suite with --network none (loopback only: the sims bind 127.0.0.1
#      ports and can never reach the live brokers) and the sources mounted read-only
#   4. prints the log, then removes the container, the image and the temp dir
# Exit status is the suite's (0 = ALL TEST GROUPS PASSED).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)          # esp32/
HOST=${E2E_HOST:-rpi1}
TAG=esp32-e2e-tmp:$$
WORK=/tmp/esp32-e2e.$$
SSH_CFG=${SSH_CFG:-$HOME/.ssh/config}

if [[ $HOST == local ]]; then
  on_host() { bash -c "$1"; }
  push_tree() { mkdir -p "$WORK" && tar -C "$HERE" --exclude=__pycache__ --exclude=sim_runtime -cf - . | tar -C "$WORK" -xf -; }
else
  on_host() { ssh -F "$SSH_CFG" "$HOST" "$1"; }
  push_tree() { tar -C "$HERE" --exclude=__pycache__ --exclude=sim_runtime -cf - . | ssh -F "$SSH_CFG" "$HOST" "mkdir -p $WORK && tar -C $WORK -xf -"; }
fi

cleanup() {
  on_host "docker rm -f esp32-e2e-$$ >/dev/null 2>&1; docker rmi -f $TAG >/dev/null 2>&1; rm -rf $WORK" || true
}
trap cleanup EXIT

push_tree
on_host "cat > $WORK/.Dockerfile <<'EOF'
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      g++ mosquitto mosquitto-clients python3 python3-pip python3-venv ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m venv /venv \
 && /venv/bin/pip install --no-cache-dir paho-mqtt==2.1.0 requests==2.32.3 flask==3.0.3
ENV PATH=/venv/bin:\$PATH PYTHONDONTWRITEBYTECODE=1 LOGDIR=/out
EOF
docker build -q -t $TAG -f $WORK/.Dockerfile $WORK >/dev/null"

set +e
on_host "docker run --name esp32-e2e-$$ --rm --network none \
  -v $WORK:/src:ro --tmpfs /out:exec --tmpfs /tmp:exec -w /src \
  $TAG bash run_all_tests.sh"
rc=$?
set -e
echo "[run_e2e_in_docker] host=$HOST exit=$rc (container, image and $WORK removed on exit)"
exit $rc
