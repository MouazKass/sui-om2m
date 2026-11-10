#!/usr/bin/env bash
# live_identity.sh - per-device identity on the REAL cluster, run ON a Pi (rpi1)
# from a copy of esp32/. The simulated sensor's Ed25519 key is generated HERE on
# first use (0600, ~/.config/om2m-esp32-sim/<device>.key) and never leaves this Pi.
#
#   sim/live_identity.sh identity [device]          print pk + Sui address (to register on-chain)
#   sim/live_identity.sh start    [device] [interval_s]   run the signing sensor in the background
#   sim/live_identity.sh attack   [device]          forged (rogue key), unsigned and tampered
#                                                   messages on the broker the sensor is on
#   sim/live_identity.sh stop     [device]          drain (SIGUSR1) and stop the sensor
#   sim/live_identity.sh log      [device]          last sensor log lines
#
# Registration and revocation are council votes, run from the laptop:
#   scripts/v9/council.sh propose rpi1 id-register   <address> <device> 3   (+ 2 approvals, execute)
#   scripts/v9/council.sh propose rpi1 id-deregister <address>              (+ 2 approvals, execute)
set -euo pipefail
CMD=${1:-identity}; DEV=${2:-esp32-dht-01}
cd "$(dirname "$0")/.."
KEYDIR=$HOME/.config/om2m-esp32-sim; install -d -m 700 "$KEYDIR"
KEY=$KEYDIR/$DEV.key
W=/tmp/espid-$DEV; mkdir -p "$W"
MEM=pi/members.conf
BROKERS=$(awk '!/^#/ && NF>=3 {printf "%s%s=%s:%s", (n++?",":""), $1, $2, $3}' "$MEM")

case "$CMD" in
identity)
  python3 sim/esp32_sim.py --device "$DEV" --key "$KEY" --print-identity ;;
start)
  INTERVAL=${3:-5}
  pgrep -f "esp32_sim.py --device $DEV " >/dev/null && { echo "already running"; exit 1; }
  nohup python3 -u sim/esp32_sim.py --device "$DEV" --key "$KEY" --brokers "$BROKERS" --home rpi2 \
    --state-file "$KEYDIR/$DEV.nvs" --interval "$INTERVAL" --keepalive 4 --home-probe 10 \
    --home-stable 30 --no-ack-failover 20 --drain 15 > "$W/sim.log" 2>&1 &
  echo "started pid $! (log $W/sim.log)" ;;
attack)
  python3 - "$DEV" "$MEM" "$W/sim.log" <<'EOF'
import json, os, re, sys, time
sys.path.insert(0, "pi")
import esp_identity as idm
import paho.mqtt.client as pm
dev, mem, simlog = sys.argv[1:4]
hosts = {l.split()[0]: l.split()[1] for l in open(mem) if l.strip() and not l.startswith("#")}
on = re.findall(r"connected (\w+) \(", open(simlog).read())
via = on[-1] if on else "rpi2"
try:
    c = pm.Client(pm.CallbackAPIVersion.VERSION2)
except AttributeError:
    c = pm.Client()
got = []
c.on_message = lambda cl, u, m: got.append(m.payload)
c.connect(hosts[via], 1883)
c.subscribe(f"sensors/{dev}/telemetry")
c.loop_start()
t = time.time()
while not got and time.time() - t < 30:
    time.sleep(0.2)
if not got:
    sys.exit("no genuine reading seen in 30 s")
g = json.loads(got[-1])
topic = f"sensors/{dev}/telemetry"
forged = {"v": 2, "id": dev, "epoch": g["epoch"], "boot": "deadbeef", "seq": 999999, "ts": int(time.time()),
          "temperature": 31.0, "humidity": 50.0}
rogue = idm.Ed25519PrivateKey.generate()
msgs = [("forged: valid signature by an attacker's own key, claiming this device id", idm.sign_obj(forged, rogue)),
        ("unsigned: the same reading with no signature", json.dumps(forged, separators=(",", ":"))),
        (f"tampered: genuine reading seq {g['seq']} with seq changed to 999998",
         got[-1].replace(f'"seq":{g["seq"]},'.encode(), b'"seq":999998,', 1))]
print(f"injecting on {via} ({hosts[via]}:1883), where the sensor is attached")
for what, p in msgs:
    c.publish(topic, p, qos=1).wait_for_publish(3)
    print(f"  sent {what}")
time.sleep(2)
c.loop_stop()
c.disconnect()
print(f"check: journalctl -u om2m-ipe-bridge on {via} | grep 'rejected message from {dev}'")
EOF
  ;;
stop)
  pkill -USR1 -f "esp32_sim.py --device $DEV " && sleep 20; tail -3 "$W/sim.log" ;;
log)
  tail -n "${3:-20}" "$W/sim.log" ;;
*) echo "usage: $0 identity|start|attack|stop|log [device]"; exit 2 ;;
esac
