#!/usr/bin/env bash
#
# bench_failover_time.sh
#
# Measures FAILOVER TAKEOVER TIME: the wall-clock interval from "the parent goes
# silent" to "a new parent is anointed on-chain" (current_parent updated, epoch
# incremented). Runs the cycle K times and reports mean/stddev.
#
# How it measures, honestly:
#   The chain is the source of truth. Each takeover increments the cluster epoch
#   and sets a new current_parent. The FailoverManager also logs a timestamp when
#   it (a) detects the timeout and (b) gets its claim confirmed. We measure the
#   interval between the moment we KILL the current parent and the moment the
#   cluster object shows a NEW epoch on-chain.
#
# Two ways to get the "new parent anointed" timestamp:
#   (A) poll the cluster object's epoch until it increments (used here) - simple,
#       robust, slightly over-counts by up to one poll interval; keep poll tight.
#   (B) parse the follower's log line for the confirmed claim - more precise but
#       log-format dependent. If you prefer (B), grep the FailoverManager log.
#
# Prereqs:
#   * 3-node cluster up, one is the current parent (rpi3 in the testbed)
#   * sui CLI on PATH (testnet), env.sh sourced so $CLUSTER / $PKG are set
#   * SSH access to the parent node to kill its container
#
# Usage:
#   source scripts/env.sh         # exports CLUSTER, PKG, etc.
#   ./bench_failover_time.sh [K]  # default K=5
#
# IMPORTANT: after each run the cluster has a new parent. The script restarts the
# killed node as a follower so the next iteration has a healthy cluster again.
# Adjust NODE/SSH details to your testbed before running.

set -uo pipefail

K="${1:-5}"
CLUSTER_ID="${CLUSTER:-}"
POLL_MS="${POLL_MS:-200}"          # poll the chain every 200ms
TIMEOUT_S="${TIMEOUT_S:-30}"       # give up on a single run after 30s

# --- testbed node wiring: EDIT to match your setup ---
PARENT_HOST="${PARENT_HOST:-10.25.96.203}"   # current parent (rpi3)
PARENT_USER="${PARENT_USER:-user}"
PARENT_CONTAINER="${PARENT_CONTAINER:-om2m}" # container name on the parent
SSHPASS_PW="${SSHPASS_PW:-user}"

if [[ -z "$CLUSTER_ID" ]]; then
  echo "ERROR: CLUSTER not set. Run 'source scripts/env.sh' first." >&2; exit 1
fi
command -v sui >/dev/null || { echo "ERROR: sui CLI not found" >&2; exit 1; }

ssh_parent() { sshpass -p "$SSHPASS_PW" ssh -o StrictHostKeyChecking=no \
  "${PARENT_USER}@${PARENT_HOST}" "$@"; }

# read the current epoch from the cluster object (parses 'epoch' u64 field)
read_epoch() {
  sui client object "$CLUSTER_ID" --json 2>/dev/null \
    | grep -o '"epoch"[^,}]*' | head -1 | grep -o '[0-9]\+'
}

echo "# Failover takeover time  cluster=$CLUSTER_ID  runs=$K  $(date -u +%Y-%m-%dT%H:%M:%SZ)"

samples=()
for ((k=1;k<=K;k++)); do
  e0=$(read_epoch); e0=${e0:-0}
  echo "  run $k: epoch before = $e0; killing parent container on $PARENT_HOST ..."

  # t0 = the instant the parent goes silent
  t0=$(date +%s.%N)
  ssh_parent "docker kill $PARENT_CONTAINER" >/dev/null 2>&1 || \
    echo "    (warn: kill returned nonzero; continuing)"

  # poll the chain until epoch increments or we time out
  newe="$e0"; t1=""
  start=$(date +%s.%N)
  while :; do
    cur=$(read_epoch); cur=${cur:-$e0}
    if [[ "$cur" -gt "$e0" ]]; then t1=$(date +%s.%N); newe="$cur"; break; fi
    now=$(date +%s.%N)
    el=$(awk -v a="$start" -v b="$now" 'BEGIN{print b-a}')
    if awk -v e="$el" -v T="$TIMEOUT_S" 'BEGIN{exit !(e>T)}'; then
      echo "    TIMEOUT after ${TIMEOUT_S}s (no epoch change) - excluding this run"; break
    fi
    sleep "$(awk -v m="$POLL_MS" 'BEGIN{print m/1000}')"
  done

  if [[ -n "$t1" ]]; then
    dt=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
    samples+=("$dt")
    echo "    takeover: epoch $e0 -> $newe in ${dt}s"
  fi

  # restore the killed node as a follower so the next run starts healthy
  echo "    restarting $PARENT_CONTAINER on $PARENT_HOST as follower ..."
  ssh_parent "docker start $PARENT_CONTAINER" >/dev/null 2>&1 || true
  sleep 8   # let it rejoin / settle before the next iteration
done

printf '%s\n' "${samples[@]}" | awk '
{ a[NR]=$1; sum+=$1; if(NR==1||$1<min)min=$1; if(NR==1||$1>max)max=$1 }
END{
  n=NR; if(n==0){print "\n# no successful takeovers measured"; exit}
  mean=sum/n; for(i=1;i<=n;i++){d=a[i]-mean; ss+=d*d}
  sd=(n>1)?sqrt(ss/(n-1)):0
  printf "\n# RESULTS (seconds)\n"
  printf "  n=%d  mean=%.2f  sd=%.2f  min=%.2f  max=%.2f\n", n,mean,sd,min,max
  printf "  -> report as: %.1f +/- %.1f s (mean +/- sd, n=%d)\n", mean,sd,n
  printf "  note: includes the %s ms heartbeat-timeout window by design.\n", "15000"
}'
