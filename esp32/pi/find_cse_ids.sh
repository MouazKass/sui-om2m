#!/usr/bin/env bash
# Prints the CSE id / name / HTTP port of the OM2M running on this Pi,
# which is what bridge.conf [om2m] needs. On the testbed this should print
# cseBaseId=in-cse, cseBaseName=in-name, cseType=in-cse (the FM4 fix) on every node. Usage: ./find_cse_ids.sh [container-name]
C=${1:-om2m-active}
echo "== config.ini inside container '$C'"
docker exec "$C" sh -c 'find / -name config.ini -path "*configuration*" 2>/dev/null | head -1 | xargs grep -E "cseBaseId|cseBaseName|cseType|jetty.http.port"' \
  || echo "container '$C' not found; try: docker ps --format '{{.Names}}'"
