#!/usr/bin/env python3
"""
simulate.py - the whole 5-node testbed on one laptop: no ESP32, no Raspberry
Pi, no wallet.

    python3 simulate.py              # dashboard at http://127.0.0.1:8000
    python3 simulate.py --selftest   # scripted run of every scenario, PASS/FAIL

What runs (all local, all simulated; the BRIDGE is the real deployable code):

  5 x simulated Pi node   rpi1..rpi5, like the testbed (every node IN-CSE-capable)
      |- MQTT broker       its own Mosquitto (process, so it can be killed)
      |- OM2M emulator     sim/mock_cse.py (/~/in-cse/in-name, v8 DAC wiring)
      '- IPE bridge        pi/om2m_ipe_bridge.py, target = the cluster's parent
  3 x simulated ESP32     sim/esp32_sim.py, cluster mode (same selector as the firmware)
  1 x chain simulator     sim/chain_sim.py (the v8 Move checks + abort codes; NOT Sui)
  1 x GraphQL stand-in    sim/mock_sui_gql.py (who the parent is, and its PoA)

From the dashboard: power a sensor off, inject bad payloads, kill a node's
broker (the sensor fails over to the rest of the cluster), make another node
the parent (writes follow), restart/stop OM2M (tree wipe / outage), protect a
sensor on-chain and read it through the DAS with an ordinary RETRIEVE, drop a
node's trust.

Needs mosquitto, paho-mqtt, requests, flask. Original single-broker version:
Hamza AlCharif (AUTHORS.md).
"""

import argparse
import json
import logging
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import webbrowser

import requests
import paho.mqtt.client as mqtt
from flask import Flask, jsonify, request, Response

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.join(HERE, "sim")
RUN = os.environ.get("SIM_RUNTIME") or os.path.join(HERE, "sim_runtime")   # override when HERE is read-only
PY = sys.executable
HDR = {"X-M2M-Origin": "admin:admin", "Accept": "application/json"}
CHAIN_PORT, GQL_PORT, UI_PORT = 19000, 19001, 8000
CLUSTER = "0xe49d6c5faf37ad48ba1213258f3bf596720f25edd9f1fcf796dc6854dd15602f"
PKG = "0x88f0b0f7f3f4feb9a01e166567ca36a49ee149b9d260a0ac5cede95d89e962f1"

NODES = {
    "rpi1": {"ip": "10.25.96.200", "trust": 100,
             "addr": "0xef9c6271d8c6cc9e1d9707a117f876e7a8679509f141879bc05ae7bcffe1d5f9"},
    "rpi2": {"ip": "10.25.96.201", "trust": 75,
             "addr": "0x4be6060abaff0b4b6b7229558887f5f054cbe7d9836ba56eff35d848e13dc1f5"},
    "rpi3": {"ip": "10.25.96.203", "trust": 75,
             "addr": "0x27dacda1bdcb3fb8dc2a4b0d77b420deea5bb43d1047592ddadb19f35764ea10"},
    "rpi4": {"ip": "10.25.96.204", "trust": 75, "addr": "0x" + "04" * 32},
    "rpi5": {"ip": "10.25.96.205", "trust": 75, "addr": "0x" + "05" * 32},
}
for _i, _n in enumerate(NODES, 1):
    NODES[_n].update(cse=18200 + _i, mqtt=18830 + _i)
ESPS = {
    "esp32-dht-01": {"home": "rpi2", "args": []},
    "esp32-ldr-01": {"home": "rpi2", "args": ["--no-dht"]},
    "esp32-dht-02": {"home": "rpi3", "args": []},
}
STATE = {"parent": "rpi1", "epoch": 5, "protected": set()}

procs = {}
events = []
last_payload = {}
ELOCK = threading.Lock()


def ev(kind, text):
    with ELOCK:
        events.append({"t": time.strftime("%H:%M:%S"), "kind": kind, "text": text})
        del events[:-300]
    print(f"[{kind}] {text}", flush=True)


# ---------------------------------------------------------------------------
# processes
# ---------------------------------------------------------------------------
def spawn(name, args, python=True):
    log = open(os.path.join(RUN, f"{name}.log"), "a", encoding="utf-8")
    procs[name] = subprocess.Popen(([PY, "-u"] if python else []) + args, stdout=log,
                                   stderr=subprocess.STDOUT, cwd=HERE)
    procs[name]._log = log.name
    return procs[name]


def kill(name, sig=signal.SIGKILL):
    p = procs.get(name)
    if p and p.poll() is None:
        p.send_signal(sig)
        try:
            p.wait(5)
        except subprocess.TimeoutExpired:
            p.kill()


def alive(name):
    p = procs.get(name)
    return bool(p and p.poll() is None)


def wait_http(url, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if requests.get(url, headers=HDR, timeout=1).ok:
                return True
        except requests.RequestException:
            pass
        time.sleep(0.2)
    return False


def cse(n):
    return f"http://127.0.0.1:{NODES[n]['cse']}"


def members_path():
    return os.path.join(RUN, "members.conf")


def write_members():
    with open(members_path(), "w") as f:
        f.write("# label host mqtt-port cse-url sui-address\n")
        for n, c in NODES.items():
            f.write(f"{n} 127.0.0.1 {c['mqtt']} {cse(n)} {c['addr']}\n")


def node_conf(n):
    c = NODES[n]
    path = os.path.join(RUN, n, "bridge.conf")
    with open(path, "w") as f:
        f.write(f"""[mqtt]
host = 127.0.0.1
port = {c['mqtt']}
client_id = om2m-ipe-bridge-{n}
[om2m]
base_url = {cse(n)}
node_label = {n}
[cluster]
self = {n}
members_file = {members_path()}
target = parent
graphql_url = http://127.0.0.1:{GQL_PORT}/graphql
cluster_id = {CLUSTER}
package_original_id = {PKG}
parent_poll_s = 1
local_fallback_after_s = 0
probe_interval_s = 2
probe_timeout_s = 0.3
announce_interval_s = 2
[bridge]
retry_interval_s = 1
stats_interval_s = 1
log_level = INFO
""")
    return path


def mappings_file(n):
    return os.path.join(RUN, n, "sui.mappings.properties")


def start_broker(n):
    spawn(f"broker-{n}", ["mosquitto", "-p", str(NODES[n]["mqtt"])], python=False)


def start_cse(n):
    spawn(f"om2m-{n}", [os.path.join(SIM, "mock_cse.py"), "--port", str(NODES[n]["cse"]),
                        "--chain-url", f"http://127.0.0.1:{CHAIN_PORT}", "--mappings", mappings_file(n)])
    ok = wait_http(f"{cse(n)}/~/in-cse")
    ev("om2m", f"{n}: OM2M {'up' if ok else 'FAILED to start'} (fresh tree, new acp ris, DAC wired)")


def start_bridge(n):
    spawn(f"bridge-{n}", [os.path.join(HERE, "pi", "om2m_ipe_bridge.py"), "-c", node_conf(n)])


def start_esp(dev, interval):
    e = ESPS[dev]
    seeds = ",".join(f"{n}=127.0.0.1:{c['mqtt']}" for n, c in NODES.items())
    spawn(f"esp-{dev}", [os.path.join(SIM, "esp32_sim.py"), "--device", dev, "--brokers", seeds,
                         "--home", e["home"], "--allow-prefix", "127.0.0.", "--interval", str(interval),
                         "--keepalive", "2", "--connect-timeout", "1", "--backoff-max", "8",
                         "--home-probe", "1", "--home-stable", str(ARGS.home_stable),
                         "--no-ack-failover", "6", "--ack-wait", "1", *e["args"]])
    ev("esp32", f"{dev} powered on (new epoch) -> home broker {e['home']}, knows the whole cluster")


def watch_brokers():
    """Capture each device's latest telemetry (for the replay button)."""
    for n, c in NODES.items():
        try:
            cl = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"ui-watch-{n}")
        except AttributeError:
            cl = mqtt.Client(client_id=f"ui-watch-{n}")

        def on_msg(_c, _u, m):
            if m.topic.endswith("/telemetry"):
                last_payload[m.topic.split("/")[1]] = m.payload
        cl.on_message = on_msg
        cl.on_connect = lambda c_, *a: c_.subscribe("sensors/+/telemetry")
        cl.reconnect_delay_set(1, 3)
        cl.connect_async("127.0.0.1", c["mqtt"])
        cl.loop_start()


def publish(n, topic, payload):
    try:
        cl = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    except AttributeError:
        cl = mqtt.Client()
    cl.connect("127.0.0.1", NODES[n]["mqtt"])
    cl.loop_start()
    cl.publish(topic, payload, qos=1).wait_for_publish(5)
    cl.loop_stop()
    cl.disconnect()


# ---------------------------------------------------------------------------
# actions (shared by the dashboard and --selftest)
# ---------------------------------------------------------------------------
def chain(path, **body):
    return requests.post(f"http://127.0.0.1:{CHAIN_PORT}{path}", json=body, timeout=10).json()


def status_of(dev):
    """The device's presence record on the parent's CSE."""
    try:
        r = requests.get(f"{cse(STATE['parent'])}/~/in-cse/in-name/{dev}/status/la", headers=HDR, timeout=1)
        return json.loads(r.json()["m2m:cin"]["con"]) if r.ok else {}
    except (requests.RequestException, ValueError, KeyError):
        return {}


def attached(dev):
    s = status_of(dev)
    return s.get("broker") if s.get("state") == "online" else None


def act_esp_off(dev):
    kill(f"esp-{dev}")
    ev("esp32", f"{dev} lost power (no goodbye) -> its broker fires the Last Will")


def act_inject(dev, kind):
    n = attached(dev) or ESPS[dev]["home"]
    t = f"sensors/{dev}/telemetry"
    if kind == "malformed":
        publish(n, t, b'{"v":2,"id":"' + dev.encode() + b'","seq":')
    elif kind == "range":
        base = json.loads(last_payload.get(dev) or "{}") or {"v": 2, "id": dev, "epoch": 1,
                                                             "boot": "00000000", "seq": 0}
        base.update(humidity=150.0, seq=base.get("seq", 0) + 100000)
        publish(n, t, json.dumps(base))
    elif kind == "replay":
        if dev not in last_payload:
            ev("warn", f"{dev}: nothing to replay yet")
            return
        other = next(x for x in NODES if x != n)          # replay into ANOTHER node's broker
        publish(other, t, last_payload[dev])
        ev("inject", f"{dev}: replayed its last reading into {other}'s broker -> stored once only")
        return
    elif kind == "spoof":
        base = json.loads(last_payload.get(dev) or "{}")
        base["id"] = "esp32-evil"
        publish(n, t, json.dumps(base))
    ev("inject", f"{dev}: sent a {kind} message via {n} -> bridge must reject it")


def act_node_restart(n):
    kill(f"om2m-{n}")
    ev("om2m", f"{n}: OM2M container recreated -> its tree is wiped")
    start_cse(n)


def act_node_stop(n):
    kill(f"om2m-{n}")
    ev("om2m", f"{n}: OM2M DOWN" + (" (it is the parent: bridges buffer)" if n == STATE["parent"] else ""))


def act_broker_stop(n):
    kill(f"broker-{n}")
    ev("mqtt", f"{n}: Mosquitto DOWN -> its sensors fail over to the rest of the cluster")


def act_broker_start(n):
    start_broker(n)
    ev("mqtt", f"{n}: Mosquitto back -> sensors homed here return after the stability window")


def act_bridge_restart(n):
    kill(f"bridge-{n}", signal.SIGTERM)
    start_bridge(n)
    ev("bridge", f"{n}: bridge restarted (broker replays retained status)")


def act_set_parent(n):
    STATE["parent"], STATE["epoch"] = n, STATE["epoch"] + 1
    requests.post(f"http://127.0.0.1:{GQL_PORT}/__set",
                  json={"parent": NODES[n]["addr"], "poa": cse(n) + "/", "epoch": STATE["epoch"]}, timeout=3)
    ev("chain", f"failover: cluster parent is now {n} (epoch {STATE['epoch']}) -> bridges write there")


def act_set_trust(n, value):
    chain("/admin/set_trust", address=NODES[n]["addr"], trust=int(value))
    ev("chain", f"{n}: trust score set to {value} (stand-in for the engine's on-chain writes)")


def reader_of(dev):
    return f"Creader-{dev}"


def rid_of(dev):
    return f"/in-cse/C{dev}"


def act_protect(dev):
    """What das/protect_sensor.sh does, against the chain simulator: a READ
    policy on the AE's resource id and one READ token per node (the DAS signs
    as whichever node is parent), then every node's mapping file; OM2M reads
    mappings only at start, so every node's OM2M restarts."""
    rid = rid_of(dev)
    chain("/admin/set_policy", rid=rid, min_trust=50, mask=1)
    for n, c in NODES.items():
        tok = chain("/admin/mint", owner=c["addr"], rid=rid, ops=1)["token"]
        with open(mappings_file(n), "a", encoding="utf-8") as f:
            f.write(f"addr.{reader_of(dev)}={c['addr']}\n")
            f.write(f"token.{reader_of(dev)}\\:\\:{rid}={tok}\n")      # escaped, as Java needs
    STATE["protected"].add(dev)
    ev("chain", f"{dev}: policy READ/min_trust 50 on {rid} + a READ token for each of the 5 nodes; "
                f"mappings added -> restarting every OM2M so the DAS loads them")
    for n in NODES:
        act_node_restart(n)


def act_dac(dev, method):
    """An ORDINARY oneM2M request by the reader against the device AE on the
    parent. OM2M's static ACP refuses it, so it is referred to the Sui DAS."""
    n = STATE["parent"]
    url = f"{cse(n)}/~/in-cse/in-name/{dev}"
    ev("das", f"{reader_of(dev)}: {method} {dev} on the parent {n} (no special headers) ...")
    try:
        r = requests.request(method, url, headers={"X-M2M-Origin": reader_of(dev), "Accept": "application/json"},
                             timeout=40)
    except requests.RequestException as e:
        ev("deny", f"{n} OM2M unreachable: {e.__class__.__name__}")
        return {"granted": False}
    logs = requests.get(f"{cse(n)}/__daslog", timeout=3).json()
    last = logs[-1] if logs else ""
    if r.status_code == 200:
        ev("grant", last)
        if method == "GET":
            lbl = [x for x in r.json().get("m2m:ae", {}).get("lbl", []) if x.startswith("latest=")]
            reading = json.loads(lbl[0][7:]) if lbl else None
            ev("grant", f"granted RETRIEVE returned the latest reading: {reading}")
            return {"granted": True, "reading": reading, "log": last}
        return {"granted": True, "log": last}
    ev("deny", last)
    return {"granted": False, "log": last}


ACTIONS = {
    "esp_off": lambda a: act_esp_off(a["dev"]),
    "esp_on": lambda a: start_esp(a["dev"], ARGS.interval),
    "inject": lambda a: act_inject(a["dev"], a["kind"]),
    "node_restart": lambda a: act_node_restart(a["node"]),
    "node_stop": lambda a: act_node_stop(a["node"]),
    "node_start": lambda a: start_cse(a["node"]),
    "broker_stop": lambda a: act_broker_stop(a["node"]),
    "broker_start": lambda a: act_broker_start(a["node"]),
    "bridge_restart": lambda a: act_bridge_restart(a["node"]),
    "set_parent": lambda a: act_set_parent(a["node"]),
    "set_trust": lambda a: act_set_trust(a["node"], a["value"]),
    "protect": lambda a: act_protect(a["dev"]),
    "gated_read": lambda a: act_dac(a["dev"], "GET"),
    "gated_delete": lambda a: act_dac(a["dev"], "DELETE"),
}


# ---------------------------------------------------------------------------
# state for the dashboard
# ---------------------------------------------------------------------------
def bridge_stats(n):
    try:
        lines = open(os.path.join(RUN, f"bridge-{n}.log"), encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        return {}, []
    st = {}
    for l in reversed(lines):
        if " stats {" in l:
            st = json.loads(l.split(" stats ", 1)[1])
            break
    notable = [l[11:19] + " " + l.split(": ", 1)[-1] for l in lines if " stats {" not in l
               and any(k in l for k in ("WARNING", "ERROR", "provisioned", "reachable again", "parent:",
                                        "stale", " is online", " is offline"))]
    return st, notable[-6:]


def sensors_on(n):
    """Devices stored on node n's CSE (only the parent's has live data)."""
    url = cse(n)
    out = {}
    d = requests.get(f"{url}/__dump", timeout=1).json()
    for dev, ae in d["aes"].items():
        if dev == "sui-das":
            continue
        s = out.setdefault(dev, {"stored": 0, "status": None, "latest": None, "dac": False, "ri": ae["ri"]})
        s["dac"] = ae["daci"] == [d["dacs"].get("sui-dac")] and ae["acpi"] == [d["acps"].get("acp_sui_dac")]
        info = d["containers"].get(f"{dev}/data")
        if info:
            s["stored"] = info["cni"]
            r = requests.get(f"{url}/~/in-cse/in-name/{dev}/data/la", headers=HDR, timeout=1)
            if r.ok:
                s["latest"] = json.loads(r.json()["m2m:cin"]["con"])
        r = requests.get(f"{url}/~/in-cse/in-name/{dev}/status/la", headers=HDR, timeout=1)
        if r.ok:
            st = json.loads(r.json()["m2m:cin"]["con"])
            s["status"], s["broker"], s["session"] = st.get("state"), st.get("broker"), st.get("session")
    return out, d


def node_state(n):
    c = NODES[n]
    out = {"name": n, "ip": c["ip"], "addr": c["addr"], "trust_default": c["trust"], "up": False,
           "parent": n == STATE["parent"], "role": "IN-CSE (parent)" if n == STATE["parent"] else "IN-CSE capable",
           "broker_alive": alive(f"broker-{n}"), "bridge_alive": alive(f"bridge-{n}"), "sensors": {}, "das": []}
    out["bridge"], out["bridge_log"] = bridge_stats(n)
    try:
        out["sensors"], d = sensors_on(n)
        out["up"] = True
        out["acp"] = d["acps"].get("acp_sui_dac")
        out["das"] = requests.get(f"{cse(n)}/__daslog", timeout=1).json()[-5:]
    except (requests.RequestException, ValueError, KeyError):
        pass
    return out


def full_state():
    try:
        ch = requests.get(f"http://127.0.0.1:{CHAIN_PORT}/state", timeout=1).json()
    except requests.RequestException:
        ch = {}
    with ELOCK:
        evs = list(events[-80:])
    nodes = [node_state(n) for n in NODES]
    par = next((x for x in nodes if x["parent"]), {"sensors": {}})
    esps = {}
    for d, e in ESPS.items():
        data = par["sensors"].get(d, {"stored": 0})
        esps[d] = {"home": e["home"], "on": alive(f"esp-{d}"), "data": data,
                   "attached": data.get("broker") if data.get("status") == "online" else None}
    return {"nodes": nodes, "esps": esps, "parent": STATE["parent"], "chain": ch, "events": evs,
            "readers": {d: reader_of(d) for d in ESPS}}


# ---------------------------------------------------------------------------
# web UI
# ---------------------------------------------------------------------------
ui = Flask(__name__)


@ui.get("/")
def index():
    return Response(open(os.path.join(SIM, "dashboard.html"), encoding="utf-8").read(), mimetype="text/html")


@ui.get("/api/state")
def api_state():
    return jsonify(full_state())


@ui.post("/api/action")
def api_action():
    a = request.get_json(force=True)
    fn = ACTIONS.get(a.get("action"))
    if not fn:
        return jsonify(error="unknown action"), 400
    threading.Thread(target=fn, args=(a,), daemon=True).start()
    return jsonify(ok=True)


# ---------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------
def selftest():
    res = []

    def check(name, ok, detail=""):
        res.append(bool(ok))
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}  {detail}", flush=True)

    def until(fn, t=25):
        end = time.time() + t
        while time.time() < end:
            try:
                v = fn()
                if v:
                    return v
            except Exception:
                pass
            time.sleep(0.3)
        return None

    sensor = lambda d: sensors_on(STATE["parent"])[0].get(d, {})
    stats = lambda n: bridge_stats(n)[0]
    D1, D2 = "esp32-dht-01", "esp32-dht-02"

    print("\n== data path: one coherent tree on the parent")
    check("readings stored on the parent (rpi1) as a DAS-wired AE",
          until(lambda: sensor(D1).get("stored", 0) >= 3 and sensor(D1).get("dac")),
          f"stored={sensor(D1).get('stored')} ri={sensor(D1).get('ri')}")
    check("...and on no other node", not any(D1 in sensors_on(n)[0] for n in NODES if n != "rpi1"))
    check("sensors attached to their home brokers",
          until(lambda: attached(D1) == "rpi2" and attached(D2) == "rpi3"),
          f"{D1}@{attached(D1)} {D2}@{attached(D2)}")

    print("\n== bad input")
    before = sum(stats(n).get("rejected", 0) for n in NODES)
    for k in ("malformed", "range", "spoof"):
        act_inject(D1, k)
    check("3 bad messages rejected", until(lambda: sum(stats(n).get("rejected", 0) for n in NODES) >= before + 3),
          f"rejected={sum(stats(n).get('rejected', 0) for n in NODES)}")
    n0 = sensor(D1).get("stored", 0)
    act_inject(D1, "replay")
    time.sleep(2)
    dup = sum(stats(n).get("duplicate", 0) + stats(n).get("duplicate_cse", 0) for n in NODES)
    check("a reading replayed into another node's broker is stored once", dup >= 1, f"duplicates dropped={dup}")

    print("\n== ESP32 power loss")
    act_esp_off(D2)
    check("Last Will -> offline", until(lambda: sensor(D2).get("status") == "offline"))
    start_esp(D2, ARGS.interval)
    check("power back -> online", until(lambda: sensor(D2).get("status") == "online"))

    print("\n== a node's broker dies: the sensor uses the rest of the cluster")
    act_broker_stop("rpi2")
    moved = until(lambda: attached(D1) not in (None, "rpi2") and attached(D1))
    check(f"{D1} failed over off rpi2", moved, f"now on {moved}")
    n1 = sensor(D1).get("stored", 0)
    check("its readings keep reaching the parent", until(lambda: sensor(D1).get("stored", 0) > n1 + 2),
          f"{n1} -> {sensor(D1).get('stored')}")
    act_broker_start("rpi2")
    check("returns home once rpi2 is stable again", until(lambda: attached(D1) == "rpi2", 40))

    print("\n== failover of the parent: writes follow the chain")
    act_set_parent("rpi3")
    check("readings now land on rpi3 (DAS-wired AE provisioned there)",
          until(lambda: sensor(D1).get("stored", 0) >= 3 and sensor(D1).get("dac")),
          f"stored on rpi3={sensor(D1).get('stored')}")

    print("\n== parent OM2M outage + wipe")
    act_node_stop("rpi3")
    time.sleep(ARGS.interval * 4)
    start_cse("rpi3")
    s = until(lambda: sensor(D1).get("stored", 0) >= 3 and sensor(D1))
    check("re-provisioned with the buffered readings", s, f"stored={s and s['stored']} dac={s and s['dac']}")
    check("status restored after the wipe", until(lambda: sensor(D1).get("status") == "online", 15))

    print("\n== on-chain access through the DAS (simulated chain)")
    r = act_dac(D1, "GET")
    check("before protecting: DENY (no Sui mapping)", not r["granted"] and "No Sui mapping" in r.get("log", ""))
    act_protect(D1)
    until(lambda: sensor(D1).get("stored", 0) >= 1 and sensor(D1).get("dac"))
    time.sleep(ARGS.interval * 2)
    r = act_dac(D1, "GET")
    check("ordinary RETRIEVE -> GRANT, returns the latest reading", r["granted"] and r.get("reading"),
          (r.get("log") or "")[:90])
    st0 = requests.get(f"http://127.0.0.1:{CHAIN_PORT}/state").json()["stats"]
    r = act_dac(D1, "DELETE")
    st1 = requests.get(f"http://127.0.0.1:{CHAIN_PORT}/state").json()["stats"]
    check("DELETE -> DENY cap_token::E_OP_NOT_ALLOWED, not submitted (no gas)",
          not r["granted"] and "E_OP_NOT_ALLOWED" in r.get("log", "") and st1["grant_submitted"] == st0["grant_submitted"],
          (r.get("log") or "")[:90])
    act_set_trust("rpi3", 30)
    r = act_dac(D1, "GET")
    check("parent's trust 30 -> DENY trust::E_TRUST_TOO_LOW", not r["granted"] and "E_TRUST_TOO_LOW" in r.get("log", ""))
    act_set_trust("rpi3", NODES["rpi3"]["trust"])
    r = act_dac(D1, "GET")
    check("trust restored -> GRANT again", r["granted"])
    aud = requests.get(f"http://127.0.0.1:{CHAIN_PORT}/state").json()["audit"]
    check("audit has grants and denials", any(a["decision"] == 1 for a in aud) and any(a["decision"] == 0 for a in aud))

    print(f"\n{sum(res)}/{len(res)} checks passed")
    return 0 if all(res) else 1


# ---------------------------------------------------------------------------
def main():
    global ARGS
    ap = argparse.ArgumentParser(description="Simulated 5-node Sui-OM2M testbed")
    ap.add_argument("--selftest", action="store_true", help="run all scenarios and exit")
    ap.add_argument("--interval", type=float, default=3.0, help="ESP32 publish interval (s)")
    ap.add_argument("--home-stable", type=float, default=20.0, help="sensor return-home window (s)")
    ap.add_argument("--latency-ms", type=int, default=None,
                    help="simulated on-chain decision time (default 1300, selftest 150)")
    ap.add_argument("--no-browser", action="store_true")
    ARGS = ap.parse_args()
    if ARGS.selftest:
        ARGS.interval = 0.5 if ARGS.interval == 3.0 else ARGS.interval
        ARGS.home_stable = 4.0 if ARGS.home_stable == 20.0 else ARGS.home_stable
    latency = ARGS.latency_ms if ARGS.latency_ms is not None else (150 if ARGS.selftest else 1300)
    if not shutil.which("mosquitto"):
        sys.exit("Need Mosquitto (each simulated Pi runs its own broker process): sudo apt install mosquitto")

    shutil.rmtree(RUN, ignore_errors=True)
    os.makedirs(RUN)
    for n in NODES:
        os.makedirs(os.path.join(RUN, n), exist_ok=True)
        open(mappings_file(n), "w").write("# sui.mappings.properties (simulated)\n")
    write_members()
    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    try:
        spawn("chain", [os.path.join(SIM, "chain_sim.py"), "--port", str(CHAIN_PORT), "--latency-ms", str(latency)])
        if not wait_http(f"http://127.0.0.1:{CHAIN_PORT}/state"):
            sys.exit("chain simulator failed to start (port 19000 busy?)")
        for n, c in NODES.items():                 # 02_bootstrap.sh equivalent
            chain("/admin/register", address=c["addr"], name=n, trust=c["trust"])
        spawn("gql", [os.path.join(SIM, "mock_sui_gql.py"), "--port", str(GQL_PORT), "--cluster", CLUSTER,
                      "--pkg", PKG, "--parent", NODES["rpi1"]["addr"], "--poa", cse("rpi1") + "/",
                      "--epoch", str(STATE["epoch"])])
        ev("chain", "5 nodes registered; parent rpi1 (simulated v8 registries and failover cluster)")
        for n in NODES:
            start_broker(n)
            start_cse(n)
        time.sleep(0.5)
        for n in NODES:
            start_bridge(n)
        watch_brokers()
        time.sleep(1.5)
        for d in ESPS:
            start_esp(d, ARGS.interval)

        if ARGS.selftest:
            time.sleep(2)
            sys.exit(selftest())

        url = f"http://127.0.0.1:{UI_PORT}"
        print(f"\n  Dashboard: {url}   (Ctrl+C to stop everything)\n", flush=True)
        if not ARGS.no_browser:
            threading.Timer(1.5, lambda: webbrowser.open(url)).start()
        ui.run(host="127.0.0.1", port=UI_PORT, threaded=True)
    except KeyboardInterrupt:
        pass
    finally:
        for name in list(procs):
            kill(name)


if __name__ == "__main__":
    main()
