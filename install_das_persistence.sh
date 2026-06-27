#!/usr/bin/env bash
# Installs systemd-based DAS auto-provisioning on all 3 nodes.
# After this, DAS resources self-recreate on every boot/container-start.
set -uo pipefail
PW=user
NODES=(10.25.96.200 10.25.96.201 10.25.96.203)
ssh_n() { sshpass -p "$PW" ssh -o StrictHostKeyChecking=no user@"$1" "$2"; }

# The provisioning script that runs ON each Pi (localhost).
read -r -d '' PROV <<'PROVEOF'
#!/usr/bin/env bash
set -uo pipefail
BASE=http://127.0.0.1:8282
ORIG=admin:admin
# wait up to 120s for OM2M to answer
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/~/in-cse" -H "X-M2M-Origin: $ORIG" || true)
  [ "$code" = "200" ] && break
  sleep 2
done
# discover ACP ri (regenerated each boot)
ACP=$(curl -s "$BASE/~/in-cse/in-name/acp_admin" -H "X-M2M-Origin: $ORIG" -H 'Accept: application/json' \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["m2m:acp"]["ri"])
except Exception: print("")')
[ -z "$ACP" ] && { echo "no ACP, abort"; exit 0; }
# ensure Csensor-001 in ACP
curl -s -o /dev/null -X PUT "$BASE/~$ACP" -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: acpu' -H 'Content-Type: application/json' \
  -d '{"m2m:acp":{"pv":{"acr":[{"acor":["admin:admin","/in-cse"],"acop":63},{"acor":["Csensor-001"],"acop":63}]}}}'
# create AE + container with acpi (ignore 409 if present)
curl -s -o /dev/null -X POST "$BASE/~/in-cse/in-name" -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: a1' -H 'Content-Type: application/json;ty=2' \
  -d "{\"m2m:ae\":{\"rn\":\"sui-das\",\"api\":\"N.sui-das.0001\",\"apn\":\"sui-das\",\"poa\":[\"sui-das\"],\"rr\":true,\"acpi\":[\"$ACP\"]}}"
curl -s -o /dev/null -X POST "$BASE/~/in-cse/in-name" -H "X-M2M-Origin: $ORIG" -H 'X-M2M-RI: c1' -H 'Content-Type: application/json;ty=3' \
  -d "{\"m2m:cnt\":{\"rn\":\"sui-protected-cnt\",\"acpi\":[\"$ACP\"]}}"
echo "DAS provisioned (ACP=$ACP)"
PROVEOF

# systemd unit: run after docker, oneshot, on boot
read -r -d '' UNIT <<'UNITEOF'
[Unit]
Description=Provision Sui-OM2M DAS resources after OM2M starts
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 45
ExecStart=/usr/local/bin/provision-das.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNITEOF

for N in "${NODES[@]}"; do
  echo "=== installing on $N ==="
  # write provisioning script
  echo "$PROV" | sshpass -p "$PW" ssh -o StrictHostKeyChecking=no user@"$N" "sudo tee /usr/local/bin/provision-das.sh >/dev/null && sudo chmod +x /usr/local/bin/provision-das.sh"
  # write + enable systemd unit
  echo "$UNIT" | sshpass -p "$PW" ssh -o StrictHostKeyChecking=no user@"$N" "sudo tee /etc/systemd/system/sui-das-provision.service >/dev/null && sudo systemctl daemon-reload && sudo systemctl enable sui-das-provision.service"
  echo "   installed + enabled on $N"
done
echo ""
echo "=== test: run the service now on rpi3 ==="
sshpass -p "$PW" ssh -o StrictHostKeyChecking=no user@10.25.96.203 "sudo systemctl start sui-das-provision.service && sleep 50 && sudo systemctl status sui-das-provision.service --no-pager | head -8"
