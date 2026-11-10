# Commands used for the v8 measurements (2026-11-10)

All commands were run from Git Bash on the publisher laptop, in the repo root, with
the VPN to the Pis up. Reads and publisher-signed steps go through WSL Ubuntu
(`sui 1.74.0`); node-signed steps run inside each node's `om2m-active` container
(`sui 1.73.0`, the node's own key). No key ever left its machine.

## Proofs (one CSV row per transaction → `proofs_v8.csv`)
    export PROOF_LOG=$PWD/evidence/v8-measurements/proofs_v8.csv
    bash proofs/01_self_scoring.sh      | tee evidence/v8-measurements/proof_01.log
    bash proofs/02_trust_engine.sh      | tee evidence/v8-measurements/proof_02.log
    ...                                   (03 … 10 the same way)
    bash proofs/06_failover.sh          # run 3 times: proof_06_run{1,2,3}.log

## Cleanup of the v7 containers
    bash scripts/v8/04_cutover.sh cleanup      # before/after disk: cleanup_v7.log

## Latency (real DAC path, on rpi3, curl to 127.0.0.1)
    bash bench/bench_v8_dac.sh 100 evidence/v8-measurements
    python bench/v8_latency_stats.py evidence/v8-measurements     # -> latency_summary.csv

## Failover (stop the parent's CSE; the plugins take over by themselves)
    bash bench/bench_v8_failover.sh evidence/v8-measurements       # -> failover_<stamp>.csv
    bash scripts/v8/04_cutover.sh verify                           # -> verify_after.log

## Gas (effects of the real transactions above, read from Sui GraphQL)
    bash bench/v8_node_digests.sh evidence/v8-measurements/node_tx_digests.csv
    python bench/v8_gas.py evidence/v8-measurements                # -> gas_per_tx.csv, gas_summary.csv
