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
declare -A IP=([rpi1]=10.25.96.200 [rpi2]=10.25.96.201 [rpi3]=10.25.96.203)
echo "kind,digest,node" > "$OUT"
for n in rpi1 rpi2 rpi3; do
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
