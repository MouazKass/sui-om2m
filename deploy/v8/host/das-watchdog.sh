#!/usr/bin/env bash
# das-watchdog.sh - re-provision DAS resources if any has gone missing.
# Installed at /usr/local/bin/das-watchdog.sh; run by das-watchdog.timer.
#
# v8: also watches the C2 resource sui-dac-ae. OM2M's DB is in-memory, so a
# container restart drops everything. Without this check, C2 would silently
# stop working after any restart while the legacy DAS AE still looked healthy.
BASE=http://127.0.0.1:8282
H='X-M2M-Origin: admin:admin'
st() { curl -s -o /dev/null -w '%{http_code}' "$BASE/~/in-cse/in-name/$1" -H "$H" 2>/dev/null || echo 000; }
cse=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/~/in-cse" -H "$H" 2>/dev/null || echo 000)
# Act only if the CSE is up but a resource is gone (404).
if [ "$cse" = "200" ] && { [ "$(st sui-das)" = "404" ] || [ "$(st sui-dac-ae)" = "404" ]; }; then
  /usr/local/bin/provision-das.sh
fi
