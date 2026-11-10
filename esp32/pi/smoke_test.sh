#!/usr/bin/env bash
# Hardware-free check ON A REAL PI: pretends to be an ESP32 with mosquitto_pub,
# then reads the reading back from the CSE the bridge writes to (the parent).
#   ./smoke_test.sh [/etc/om2m-ipe-bridge/bridge.conf]
set -uo pipefail
CONF=${1:-/etc/om2m-ipe-bridge/bridge.conf}
BR=/opt/om2m-ipe-bridge/om2m_ipe_bridge.py
[[ -f $BR ]] || { echo "run sudo ./install.sh <node> first"; exit 1; }
get() { python3 -c "import configparser;c=configparser.ConfigParser();c.read('$CONF');print(c.get('$1','$2'))"; }
MQ=$(get mqtt host); MP=$(get mqtt port); NODE=$(get om2m node_label); DEV=smoke-test-$NODE
H=(-H "X-M2M-Origin: $(get om2m originator)" -H "Accept: application/json")

echo "1) bridge --check against its target CSE (creates, writes, rejects a duplicate, deletes a probe)"
OUT=$(python3 "$BR" -c "$CONF" --check 2>&1); RC=$?
echo "$OUT" | sed 's/^/   /'
TARGET=$(echo "$OUT" | sed -n 's/^target \([^ ]*\) .*/\1/p' | head -1)
[[ $RC -eq 0 && -n "$TARGET" ]] || { echo "   FAILED (rc=$RC)"; exit 1; }

echo "2) publishing a fake ESP32 reading to $MQ:$MP"
EPOCH=$(( $(date +%s) - 1700000000 ))
mosquitto_pub -h "$MQ" -p "$MP" -t "sensors/$DEV/telemetry" \
  -m "{\"v\":2,\"id\":\"$DEV\",\"epoch\":$EPOCH,\"boot\":\"smoke\",\"seq\":0,\"ts\":$(date +%s),\"temperature\":24.5,\"humidity\":55.0}"
sleep 3

echo "3) reading it back from $TARGET (latest contentInstance of $DEV/data)"
curl -s "${H[@]}" "$TARGET/~/in-cse/in-name/$DEV/data/la" | sed 's/^/   /'; echo
echo "   -> expect m2m:cin, rn e$EPOCH-s0, con containing temperature 24.5"
echo "4) the AE is DAS-wired"
curl -s "${H[@]}" "$TARGET/~/in-cse/in-name/$DEV" | python3 -c 'import sys,json
a=json.load(sys.stdin).get("m2m:ae",{}); print("   ri", a.get("ri"), "acpi", a.get("acpi"), "daci", a.get("daci"))'
echo "   (the smoke-test AE is left in place; delete with: curl -X DELETE ${H[*]} $TARGET/~/in-cse/in-name/$DEV)"
