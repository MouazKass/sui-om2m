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
#   (v2.2: signed acks + durable replay floor)
#   sim/live_identity.sh forge-acks [device] [secs] publish FORGED acks (unsigned, rogue key,
#                                                   wrong device) for every reading seen on the
#                                                   broker the sensor is on, for secs seconds
#   sim/live_identity.sh capture  [device]          save one genuine signed reading ($W/old.json)
#   sim/live_identity.sh replay   [device] <node>   re-publish that saved reading to <node>'s broker
#
# start pins the bridges' ack public keys from pi/ack_keys.txt (deploy/v9/ack_keys/trusted.txt)
# when that file exists: the sensor then accepts only acks signed by one of them.
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
ACKS=pi/ack_keys.txt; ACKARG=(); [[ -f $ACKS ]] && ACKARG=(--ack-keys "$ACKS")
BROKERS=$(awk '!/^#/ && NF>=3 {printf "%s%s=%s:%s", (n++?",":""), $1, $2, $3}' "$MEM")

case "$CMD" in
identity)
  python3 sim/esp32_sim.py --device "$DEV" --key "$KEY" --print-identity ;;
start)
  INTERVAL=${3:-5}
  pgrep -f "esp32_sim.py --device $DEV " >/dev/null && { echo "already running"; exit 1; }
  nohup python3 -u sim/esp32_sim.py --device "$DEV" --key "$KEY" --brokers "$BROKERS" --home rpi2 \
    --state-file "$KEYDIR/$DEV.nvs" --interval "$INTERVAL" --keepalive 4 --home-probe 10 \
    --home-stable 30 --no-ack-failover 20 --drain 15 "${ACKARG[@]}" > "$W/sim.log" 2>&1 &
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
forge-acks|capture|replay)
  python3 - "$CMD" "$DEV" "$MEM" "$W" "${3:-}" <<'EOF'
import json, os, re, sys, time
sys.path.insert(0, "pi")
import esp_identity as idm
import paho.mqtt.client as pm
cmd, dev, mem, w, arg = sys.argv[1:6]
hosts = {l.split()[0]: l.split()[1] for l in open(mem) if l.strip() and not l.startswith("#")}
on = re.findall(r"connected (\w+) \(", open(os.path.join(w, "sim.log")).read())
via = on[-1] if on else "rpi2"
def client(host):
    try:
        c = pm.Client(pm.CallbackAPIVersion.VERSION2)
    except AttributeError:
        c = pm.Client()
    c.connect(host, 1883)
    c.loop_start()
    return c
old = os.path.join(w, "old.json")
if cmd == "capture":
    got = []
    c = client(hosts[via])
    c.on_message = lambda cl, u, m: got.append(m.payload)
    c.subscribe(f"sensors/{dev}/telemetry")
    t = time.time()
    while not any(b'"sig":"' in g for g in got) and time.time() - t < 30:
        time.sleep(0.2)
    g = [x for x in got if b'"sig":"' in x]
    if not g:
        sys.exit("no genuine reading seen in 30 s")
    open(old, "wb").write(g[-1])
    d = json.loads(g[-1])
    print(f"captured genuine reading epoch {d['epoch']} seq {d['seq']} on {via} -> {old}")
elif cmd == "replay":
    node = arg or via
    raw = open(old, "rb").read()
    d = json.loads(raw)
    c = client(hosts[node])
    c.publish(f"sensors/{dev}/telemetry", raw, qos=1).wait_for_publish(3)
    time.sleep(1)
    print(f"replayed genuine reading epoch {d['epoch']} seq {d['seq']} to {node} ({hosts[node]}:1883)")
else:
    secs = float(arg or 60)
    rogue = idm.Ed25519PrivateKey.generate()
    n = [0]
    c = client(hosts[via])
    def forge(cl, u, m):
        try:
            r = json.loads(m.payload)
        except ValueError:
            return
        if "seq" not in r:
            return
        base = {"id": dev, "seq": r["seq"], "node": via, "epoch": r.get("epoch")}
        for f in (json.dumps(base), idm.sign_ack(base, rogue), idm.sign_ack(dict(base, id="esp32-other-99"), rogue)):
            cl.publish(f"sensors/{dev}/ack", f, qos=1)
            n[0] += 1
        print(f"  forged 3 acks for seq {r['seq']}", flush=True)
    c.on_message = forge
    c.subscribe(f"sensors/{dev}/telemetry")
    print(f"forging acks on {via} ({hosts[via]}:1883) for {secs:g} s", flush=True)
    time.sleep(secs)
    print(f"{n[0]} forged acks published")
EOF
  ;;
stop)
  pkill -USR1 -f "esp32_sim.py --device $DEV " && sleep 20; tail -3 "$W/sim.log" ;;
log)
  tail -n "${3:-20}" "$W/sim.log" ;;
*) echo "usage: $0 identity|start|attack|stop|log [device]"; exit 2 ;;
esac
