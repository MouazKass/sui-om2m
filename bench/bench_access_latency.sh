#!/usr/bin/env bash
#
# bench_access_latency.sh
#
# Measures end-to-end access-decision latency on the NATIVE path: the time from
# issuing a DAS access request to the decision returning. Runs N times and
# reports mean, stddev, min, max, p50, p95.
#
# This is the "what does one on-chain access decision cost in wall-clock time?"
# number. Run it against a properly provisioned originator so every request is a
# real GRANT (a DENY aborts earlier and would skew the numbers downward).
#
# Prereqs:
#   * the IN-CSE node is up, plugin loaded, sui.use.native.rpc=true
#   * the DAS resources (sui-das AE, sui-protected-cnt) exist (they are recreated
#     each boot; if you just rebooted, hit the node once to ensure they're there)
#   * the publisher wallet has gas
#
# Usage:
#   ./bench_access_latency.sh [N]        # default N=30
#
# Run it ON or NEAR the IN-CSE (localhost) to avoid adding network RTT to the
# measurement. If you run it remotely, the number includes your client->node hop.

set -uo pipefail

N="${1:-30}"
NODE="${NODE:-http://10.25.96.200:8282}"
ORIGIN="${ORIGIN:-admin:admin}"
# The DAS NOTIFY target (matches the testbed: sui-das AE under in-cse/in-name).
URL="$NODE/~/in-cse/in-name/sui-das"

# A real access request body: originator Csensor-001 reading the protected cnt.
read -r -d '' BODY <<'JSON'
{"m2m:sec":{"sit":1,"dreq":{"or":"Csensor-001","op":1,"rid":"/in-cse/in-name/sui-protected-cnt","rty":4}}}
JSON

echo "# Access-decision latency, native path"
echo "# node=$NODE  runs=$N  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# (warming up with 3 discarded requests...)"

# Warm-up: first calls pay JIT/connection costs; discard them.
for i in 1 2 3; do
  curl -s -o /dev/null -X POST "$URL" \
    -H "X-M2M-Origin: $ORIGIN" -H "Content-Type: application/json;ty=4" \
    -d "$BODY" >/dev/null 2>&1 || true
done

samples=()
fail=0
for ((i=1;i<=N;i++)); do
  # %{time_total} is wall-clock seconds for the whole request, high precision.
  t=$(curl -s -o /dev/null -w '%{time_total}' -X POST "$URL" \
        -H "X-M2M-Origin: $ORIGIN" -H "Content-Type: application/json;ty=4" \
        -d "$BODY" 2>/dev/null)
  rc=$?
  if [[ $rc -ne 0 || -z "$t" ]]; then
    fail=$((fail+1)); continue
  fi
  # convert seconds -> milliseconds
  ms=$(awk -v s="$t" 'BEGIN{printf "%.1f", s*1000}')
  samples+=("$ms")
  printf '  run %2d: %s ms\n' "$i" "$ms"
done

# stats in awk (mean, sample stddev, min/max, p50, p95)
printf '%s\n' "${samples[@]}" | awk '
{ a[NR]=$1; sum+=$1; if(NR==1||$1<min)min=$1; if(NR==1||$1>max)max=$1 }
END{
  n=NR; if(n==0){print "no samples"; exit}
  mean=sum/n
  for(i=1;i<=n;i++){d=a[i]-mean; ss+=d*d}
  sd=(n>1)?sqrt(ss/(n-1)):0
  # sort for percentiles
  for(i=1;i<=n;i++) for(j=i+1;j<=n;j++) if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t}
  p50=a[int(0.50*(n-1))+1]; p95=a[int(0.95*(n-1))+1]
  printf "\n# RESULTS (ms)\n"
  printf "  n=%d  mean=%.1f  sd=%.1f  min=%.1f  max=%.1f  p50=%.1f  p95=%.1f\n", n,mean,sd,min,max,p50,p95
  printf "  -> report as: %.0f +/- %.0f ms (mean +/- sd, n=%d)\n", mean,sd,n
}'
[[ $fail -gt 0 ]] && echo "# WARNING: $fail request(s) failed and were excluded"
