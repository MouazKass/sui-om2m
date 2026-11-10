#!/usr/bin/env bash
# protected_read.sh - read an ESP32 THROUGH the on-chain check, with an ORDINARY
# oneM2M request (no NOTIFY, no special headers). Run on the parent node.
#
#   ./protected_read.sh esp32-dht-01 Cesp32-reader-01
#
#   1. RETRIEVE the device AE as the reader. The static ACP (acp_sui_dac)
#      grants only admin, so OM2M refers the request to the Sui DAS through
#      DynamicAuthorizationConsultation. Expect HTTP 200 and the AE's
#      "latest=" label = the newest reading; the plugin log shows Sui GRANT.
#   2. DELETE the AE as the reader: the token is READ-only, so expect 403 and a
#      Sui DENY (cap_token E_OP_NOT_ALLOWED) found by the DAS's free
#      simulation - no transaction is submitted (F3), so no gas is spent.
#   3. Control: RETRIEVE the data container as the reader. A <container> is
#      never referred to a DAS (ContainerController calls checkACP only), so
#      expect 403 with no Sui log line. This is why the bridge mirrors the
#      latest reading into the AE label.
set -uo pipefail
DEV=${1:?device}; READER=${2:?reader originator}; BASE=${BASE:-http://127.0.0.1:8282}
AE="$BASE/~/in-cse/in-name/$DEV"
since() { docker logs --since "$1" om2m-active 2>&1 | grep -E "Sui (GRANT|DENY)|No Sui mapping" | tail -2 | sed 's/^/   /'; }

echo "== 1. RETRIEVE $DEV as $READER -> expect GRANT"
T=$(date -u +%FT%TZ)
curl -s -w '\n   HTTP %{http_code}\n' "$AE" -H "X-M2M-Origin: $READER" -H 'Accept: application/json' \
  | python3 -c 'import sys,json
raw=sys.stdin.read(); body,_,code=raw.rpartition("\n   HTTP ")
try:
  lbl=[x for x in json.loads(body)["m2m:ae"]["lbl"] if x.startswith("latest=")]
  print("   latest reading:", lbl[0][7:] if lbl else "(none yet)")
except Exception: print("   ", body[:200])
print("   HTTP", code)'
sleep 1; since "$T"

echo "== 2. DELETE $DEV as $READER -> expect 403 / DENY, no transaction"
T=$(date -u +%FT%TZ)
curl -s -o /dev/null -w '   HTTP %{http_code}\n' -X DELETE "$AE" -H "X-M2M-Origin: $READER"
sleep 1; since "$T"

echo "== 3. control: RETRIEVE $DEV/data/la as $READER -> expect 403, no Sui line"
T=$(date -u +%FT%TZ)
curl -s -o /dev/null -w '   HTTP %{http_code}\n' "$AE/data/la" -H "X-M2M-Origin: $READER" -H 'Accept: application/json'
sleep 1; since "$T"; echo "   (nothing above = the DAS was not consulted, as expected)"
