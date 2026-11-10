#!/usr/bin/env bash
# v8_node_digests.sh - scrape the transaction digests the running plugins sent
# (lease anchors, PoA publications, claims, trust writes) from each node's
# container log, as kind,digest CSV for bench/v8_gas.py.
#
# Usage: bench/v8_node_digests.sh [OUTFILE] [SINCE]   (SINCE: docker logs --since, default 48h)
set -euo pipefail
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/evidence/v8-measurements/node_tx_digests.csv}"
SINCE="${2:-48h}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_suiom2m}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/scripts/lib/inventory.sh"; inv_load   # nodes: deploy/inventory.tsv
declare -A IP=(); for _n in "${INV_ALL[@]}"; do IP[$_n]=${INV_IP[$_n]}; done
echo "kind,digest,node" > "$OUT"
for n in $(inv_nodes active); do
  ssh -i "$KEY" -o BatchMode=yes "user@${IP[$n]}" "docker logs --since $SINCE om2m-active 2>&1" | python -c '
import sys,re
pats=[("plugin_renew_lease", r"Lease anchored .*digest=(\w{32,})"),
      ("plugin_set_parent_poa", r"PoA published on-chain: .*digest=(\w{32,})"),
      ("plugin_claim_parent[ok]", r"CLAIM ACCEPTED .*digest=(\w{32,})"),
      ("plugin_claim_parent[abort]", r"Claim rejected on-chain: .*digest=(\w{32,})"),
      ("plugin_trust_write", r"\[trust\] .* tier \d+->\d+: .*digest=(\w{32,})")]
node=sys.argv[1]
for l in sys.stdin:
    for k,p in pats:
        m=re.search(p,l)
        if m: print(f"{k},{m.group(1)},{node}")
' "$n" >> "$OUT"
done
echo "# $(($(wc -l < "$OUT")-1)) digests -> $OUT"
