#!/usr/bin/env bash
#
# bench_gas_per_op.sh
#
# Reports the gas cost (in MIST and SUI) of each on-chain operation by reading it
# straight out of the transaction effects. Sui reports computationCost,
# storageCost, and storageRebate per transaction; the net gas a node pays is
#   net = computationCost + storageCost - storageRebate
#
# This script does NOT submit transactions. It takes transaction DIGESTS you have
# already produced (one per operation type) and pulls their gas breakdown. That
# keeps the numbers honest: they are the real costs of the real operations you
# ran, not a synthetic estimate.
#
# Collect one representative digest per operation first:
#   * ACCESS GRANT      - from a native DAS access (the plugin logs the digest;
#                         or run scripts and capture it)
#   * TIER CHANGE       - from a trust delta that crosses a tier (submitTrustDelta)
#   * FAILOVER CLAIM    - from a claim_parent transaction
# (optionally also: MINT, REVOKE, BURN - add more lines below)
#
# Usage:
#   ./bench_gas_per_op.sh
# then paste digests when prompted, OR edit the DIGESTS map below and run.
#
# Prereqs: sui CLI on PATH, active env = testnet.

set -uo pipefail

# Option A: hard-code digests here (recommended for repeatability), e.g.
#   declare -A DIGESTS=(
#     ["access-grant"]="n6kpsL3PtuPNuBRcANLHFarYLjKJ6WeWvQajN69C7uJ"
#     ["tier-change"]="..."
#     ["failover-claim"]="..."
#   )
declare -A DIGESTS=(
  ["access-grant"]=""
  ["tier-change"]=""
  ["failover-claim"]=""
)

# Option B: if a digest is empty, prompt for it.
for op in "access-grant" "tier-change" "failover-claim"; do
  if [[ -z "${DIGESTS[$op]}" ]]; then
    read -r -p "digest for [$op] (blank to skip): " d
    DIGESTS[$op]="$d"
  fi
done

mist_to_sui() { awk -v m="$1" 'BEGIN{printf "%.6f", m/1000000000}'; }

echo ""
echo "# Gas per operation (testnet)  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf "%-16s %14s %14s %14s %14s %12s\n" "operation" "computation" "storage" "rebate" "net(MIST)" "net(SUI)"
printf "%-16s %14s %14s %14s %14s %12s\n" "----------------" "-----------" "-------" "------" "---------" "--------"

for op in "access-grant" "tier-change" "failover-claim"; do
  d="${DIGESTS[$op]}"
  [[ -z "$d" ]] && { printf "%-16s %14s\n" "$op" "(skipped)"; continue; }
  # pull effects as JSON; gasUsed has the three fields.
  json=$(sui client tx-block "$d" --json 2>/dev/null)
  if [[ -z "$json" ]]; then
    printf "%-16s %14s\n" "$op" "(not found)"; continue
  fi
  comp=$(echo "$json"   | grep -o '"computationCost"[^,]*' | head -1 | grep -o '[0-9]\+')
  stor=$(echo "$json"   | grep -o '"storageCost"[^,]*'     | head -1 | grep -o '[0-9]\+')
  reb=$(echo "$json"    | grep -o '"storageRebate"[^,]*'   | head -1 | grep -o '[0-9]\+')
  comp=${comp:-0}; stor=${stor:-0}; reb=${reb:-0}
  net=$((comp + stor - reb))
  printf "%-16s %14s %14s %14s %14s %12s\n" "$op" "$comp" "$stor" "$reb" "$net" "$(mist_to_sui $net)"
done

echo ""
echo "# net = computation + storage - rebate. 1 SUI = 1e9 MIST."
echo "# Tip: run each op 3-5 times and average; storage cost can vary if an"
echo "#      object is created vs mutated (e.g. first tier-change for a node)."
