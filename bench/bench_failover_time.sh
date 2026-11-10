#!/usr/bin/env bash
# bench_failover_time.sh - failover takeover time, dynamic current-parent.
set -uo pipefail
INV_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${REPO:-$INV_REPO}"
# shellcheck source=../scripts/lib/inventory.sh
. "$INV_REPO/scripts/lib/inventory.sh"; inv_load   # nodes: deploy/inventory.tsv
K="${1:-5}"
CLUSTER_ID="${CLUSTER:-}"
POLL_MS="${POLL_MS:-200}"
TIMEOUT_S="${TIMEOUT_S:-30}"
PARENT_USER="${PARENT_USER:-user}"
SSHPASS_PW="${SSHPASS_PW:-user}"

declare -A NODE_HOST=() NODE_CONT=()
for _n in $(inv_nodes active); do
  NODE_HOST[${INV_ADDR[$_n]}]=${INV_IP[$_n]}; NODE_CONT[${INV_ADDR[$_n]}]=om2m-active
done

[[ -z "$CLUSTER_ID" ]] && { echo "ERROR: CLUSTER not set. source scripts/env.sh first." >&2; exit 1; }
command -v sui >/dev/null || { echo "ERROR: sui CLI not found" >&2; exit 1; }

ssh_node() { local host="$1"; shift; ssh -F "$INV_SSH_CONFIG" -i "${SSH_KEY:-$HOME/.ssh/id_ed25519_suiom2m}" -o BatchMode=yes "${PARENT_USER}@${host}" "$@"; }   # v8: key auth
read_parent() { sui client object "$CLUSTER_ID" --json 2>/dev/null | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["content"]["current_parent"])
except Exception: pass'; }
read_epoch() { sui client object "$CLUSTER_ID" --json 2>/dev/null | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["content"]["epoch"])
except Exception: pass'; }

echo "# Failover takeover time  cluster=$CLUSTER_ID  runs=$K  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
samples=()
for ((k=1;k<=K;k++)); do
  e0=$(read_epoch); e0=${e0:-0}
  paddr=$(read_parent)
  phost="${NODE_HOST[$paddr]:-}"; pcont="${NODE_CONT[$paddr]:-}"
  if [[ -z "$phost" || -z "$pcont" ]]; then
    echo "  run $k: parent $paddr not in map - skipping."; continue
  fi
  echo "  run $k: epoch=$e0, parent=$phost ($pcont); killing it ..."
  t0=$(date +%s.%N)
  ssh_node "$phost" "docker kill $pcont" >/dev/null 2>&1 || echo "    (warn: kill returned nonzero)"
  newe="$e0"; t1=""; start=$(date +%s.%N)
  while :; do
    cur=$(read_epoch); cur=${cur:-$e0}
    if [[ "$cur" -gt "$e0" ]]; then t1=$(date +%s.%N); newe="$cur"; break; fi
    el=$(awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN{print b-a}')
    awk -v e="$el" -v T="$TIMEOUT_S" 'BEGIN{exit !(e>T)}' && { echo "    TIMEOUT ${TIMEOUT_S}s - excluding"; break; }
    sleep "$(awk -v m="$POLL_MS" 'BEGIN{print m/1000}')"
  done
  if [[ -n "$t1" ]]; then
    dt=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
    samples+=("$dt"); echo "    takeover: epoch $e0 -> $newe in ${dt}s"
  fi
  echo "    restarting $pcont on $phost as follower ..."
  ssh_node "$phost" "docker start $pcont" >/dev/null 2>&1 || true
  sleep 8
done
printf '%s\n' "${samples[@]}" | awk '
{ a[NR]=$1; sum+=$1; if(NR==1||$1<min)min=$1; if(NR==1||$1>max)max=$1 }
END{ n=NR; if(n==0){print "\n# no successful takeovers"; exit}
  mean=sum/n; for(i=1;i<=n;i++){d=a[i]-mean; ss+=d*d}; sd=(n>1)?sqrt(ss/(n-1)):0
  printf "\n# RESULTS (seconds)\n  n=%d  mean=%.2f  sd=%.2f  min=%.2f  max=%.2f\n", n,mean,sd,min,max
  printf "  -> report as: %.1f +/- %.1f s (mean +/- sd, n=%d)\n", mean,sd,n }'
