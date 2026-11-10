#!/usr/bin/env bash
# run_all_tests.sh - every offline check of the ESP32 layer, in order.
# Linux/WSL. Needs: g++, python3 with paho-mqtt + requests + flask, mosquitto.
#   ./run_all_tests.sh            (logs under $LOGDIR, default ./sim_runtime/tests)
set -uo pipefail
cd "$(dirname "$0")"
LOGDIR=${LOGDIR:-$PWD/sim_runtime/tests}; rm -rf "$LOGDIR"; mkdir -p "$LOGDIR"
FAIL=0
step() { echo; echo "### $*"; }
run() { "$@" || FAIL=$((FAIL + 1)); }

step "1. firmware selector (cluster.h) against the shared vectors"
run bash -c "g++ -std=c++17 -Wall -Wextra -o '$LOGDIR/cluster_test' sim/firmware_hostcheck/cluster_test.cpp && '$LOGDIR/cluster_test' sim/selector_vectors.txt"
step "2. simulator selector (esp32_sim.py) against the same vectors"
run python3 tests/test_selector.py
step "3. firmware host build: the real .ino, virtual time, simulated cluster"
run bash -c "cd sim/firmware_hostcheck && g++ -std=c++17 -Wall -I stubs -o '$LOGDIR/fw_host' host_main.cpp \
  && '$LOGDIR/fw_host' > '$LOGDIR/fw_pub.txt' 2> '$LOGDIR/fw_host.err'; rc=\$?; sed -n '/host-check results/,\$p' '$LOGDIR/fw_host.err'; exit \$rc"
step "4. bridge unit tests"
run python3 tests/test_bridge_unit.py
step "5. single-node end-to-end (Hamza's original scenarios, v2 layout)"
run env E2E_LOGDIR="$LOGDIR/e2e" FW_PUB="$LOGDIR/fw_pub.txt" python3 sim/run_e2e.py
step "6. 5-node cluster end-to-end"
run env E2E_LOGDIR="$LOGDIR/cluster" python3 sim/run_cluster_e2e.py
step "7. dashboard simulator self-test"
run python3 simulate.py --selftest
echo
[[ $FAIL -eq 0 ]] && echo "ALL TEST GROUPS PASSED" || echo "$FAIL TEST GROUP(S) FAILED"
exit $FAIL
