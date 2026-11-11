#!/usr/bin/env python3
"""
run_cluster_e2e.py - the cluster scenarios, on one machine, with no hardware.

Five simulated Pis (rpi1..rpi5), each with
    a real Mosquitto broker      (advertised through tcp_proxy.py, so links can fail)
    the oneM2M emulator          (mock_cse.py, v8 DAC wiring)
    the REAL bridge              (pi/om2m_ipe_bridge.py, target = parent)
plus chain_sim.py (the Move decision logic, NOT Sui), mock_sui_gql.py (the two
GraphQL reads the bridge makes) and one simulated ESP32 (esp32_sim.py, the same
selector as the firmware) whose seed list knows only rpi1..rpi4.

    python3 sim/run_cluster_e2e.py        (needs: mosquitto, paho-mqtt, requests, flask)

Scenarios
  C0  attach + placement     sensor on its home broker (rpi2); readings land on the
                             PARENT's CSE (rpi1) as a DAS-wired AE; nowhere else
  C1  home broker dies       fails over (next broker) within 10 s; buffered readings re-sent
  C2  stale Last Will        one-way partition: the sensor moves on, the old broker fires
                             its Last Will late; the bridges ignore it (session order)
  C3  home returns           sensor moves back only after the stability window; clears
                             its retained presence on the broker it left
  C4  parent change          the chain names rpi3: writes move to rpi3's CSE mid-stream
  C5  chain unreadable       GraphQL down: the last known parent is kept, nothing lost
  C6  new node               rpi5 added to members_file -> retained om2m/cluster/brokers ->
                             the sensor learns it and uses it when rpi1..rpi4 are down
  C7  protected read         ordinary RETRIEVE of the device AE by a reader -> DAS GRANT
                             with the latest reading; DELETE -> DENY without a paid tx;
                             unmapped originator -> DENY; the data container is never DAS'd
  C9  bridge down            the broker is up but its bridge died: nothing is acked, so
                             the sensor fails over instead of losing readings. Meanwhile an
                             attacker on that broker publishes FORGED acks (unsigned, rogue
                             key, wrong device) for every reading: the sensor trusts only
                             acks signed by a pinned bridge key, so it still fails over and
                             nothing is dropped unstored (C8)
 C10  device identity      every message is signed by the sensor's own key and accepted only
                             while that key is registered on-chain for the device: forged
                             (rogue key), tampered and unsigned messages are rejected; after a
                             deregistration (council revoke) readings stop, after re-registering
                             the backlog is re-sent and nothing is lost
  C8  exactly once           every reading stored, none twice (within each tree), union
                             complete across the parent change
 C11  replay floor           the sensor power-cycles (epoch +1). A genuine signed reading of
                             the OLD epoch is replayed (a) to its home bridge after that
                             bridge restarts: rejected from its durable replay.json;
                             (b) to a bridge whose state was wiped: rejected from the floor
                             it reads off the parent CSE. Nothing is stored.
"""

import base64
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PY = sys.executable
HDR = {"X-M2M-Origin": "admin:admin", "Accept": "application/json"}
CLUSTER = "0xe49d6c5faf37ad48ba1213258f3bf596720f25edd9f1fcf796dc6854dd15602f"
PKG = "0x88f0b0f7f3f4feb9a01e166567ca36a49ee149b9d260a0ac5cede95d89e962f1"
CHAIN, GQL = 19210, 19211
DEV, READER = "esp32-dht-01", "Creader-01"
REGISTRY = "0x1d"                     # mock identity registry id (mock_sui_gql.py)
RID = f"/in-cse/C{DEV}"
N = {f"rpi{i}": {"mqtt": 18840 + i, "proxy": 18850 + i, "cse": 18290 + i,
                 "addr": "0x" + f"{i:02x}" * 32} for i in range(1, 6)}

procs, results = {}, []
tmp = os.environ.get("E2E_LOGDIR") or tempfile.mkdtemp(prefix="cluster-e2e-")
os.makedirs(tmp, exist_ok=True)


def start(name, args):
    log = open(os.path.join(tmp, f"{name}.log"), "a")
    p = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
    p._log = log.name
    procs[name] = p
    return p


def stop(name, sig=signal.SIGTERM, wait=8):
    p = procs.get(name)
    if p and p.poll() is None:
        p.send_signal(sig)
        try:
            p.wait(wait)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def until(fn, timeout=20, step=0.2):
    end = time.time() + timeout
    while time.time() < end:
        try:
            v = fn()
            if v:
                return v
        except Exception:
            pass
        time.sleep(step)
    return None


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}  {detail}", flush=True)


def cse_url(n):
    return f"http://127.0.0.1:{N[n]['cse']}"


def dump(n):
    return requests.get(f"{cse_url(n)}/__dump", timeout=3).json()


def rns(n):
    c = dump(n)["containers"].get(f"{DEV}/data")
    return c["rns"] if c else []


def latest_status(n):
    r = requests.get(f"{cse_url(n)}/~/in-cse/in-name/{DEV}/status/la", headers=HDR, timeout=3)
    return json.loads(r.json()["m2m:cin"]["con"]) if r.status_code == 200 else None


def esp_log():
    return open(procs["esp"]._log).read()


def events():
    return [l for l in esp_log().splitlines() if " event " in l]


def bridge_stats(n):
    lines = [l for l in open(procs[f"bridge-{n}"]._log) if " stats {" in l]
    return json.loads(lines[-1].split(" stats ", 1)[1]) if lines else {}


def gql_set(**kw):
    requests.post(f"http://127.0.0.1:{GQL}/__set", json=kw, timeout=3)


def members_file(labels):
    path = os.path.join(tmp, "members.conf")
    with open(path, "w") as f:
        f.write("# label host mqtt-port cse-url sui-address (generated by run_cluster_e2e.py)\n")
        for n in labels:
            f.write(f"{n} 127.0.0.1 {N[n]['proxy']} {cse_url(n)} {N[n]['addr']}\n")
    return path


def bridge_conf(n, members):
    path = os.path.join(tmp, f"bridge-{n}.conf")
    with open(path, "w") as f:
        f.write(f"""[mqtt]
host = 127.0.0.1
port = {N[n]['mqtt']}
client_id = ipe-bridge-{n}
[om2m]
base_url = {cse_url(n)}
node_label = {n}
[cluster]
self = {n}
members_file = {members}
target = parent
graphql_url = http://127.0.0.1:{GQL}/graphql
cluster_id = {CLUSTER}
package_original_id = {PKG}
parent_poll_s = 1
local_fallback_after_s = 0
probe_interval_s = 1
probe_timeout_s = 0.3
announce_interval_s = 1
announce_refresh_s = 30
[identity]
mode = require
registry_id = {REGISTRY}
cache_ttl_s = 2
negative_ttl_s = 1
[ack]
sign = true
[bridge]
retry_interval_s = 0.5
stats_interval_s = 1
log_level = INFO
state_dir = {os.path.join(tmp, "state-" + n)}
""")
    return path


def chain(path, **body):
    return requests.post(f"http://127.0.0.1:{CHAIN}{path}", json=body, timeout=5).json()


def seen_seqs(n):
    return [int(r.split("-s")[1]) for r in rns(n)]


def main():
    for tool in ("mosquitto",):
        if not shutil.which(tool):
            sys.exit(f"missing {tool}: sudo apt install mosquitto mosquitto-clients")
    print(f"logs: {tmp}")

    # ---- the chain: nodes registered, a READ policy and one token per node --------
    start("chain", [PY, os.path.join(HERE, "chain_sim.py"), "--port", str(CHAIN), "--latency-ms", "50"])
    until(lambda: requests.get(f"http://127.0.0.1:{CHAIN}/state", timeout=1).ok, 10)
    for n, c in N.items():
        chain("/admin/register", address=c["addr"], name=n, trust=75)
    chain("/admin/set_policy", rid=RID, min_trust=50, mask=1)
    for n, c in N.items():
        # the DAS signs as the node it runs on, so each node needs its own token
        tok = chain("/admin/mint", owner=c["addr"], rid=RID, ops=1)["token"]
        with open(os.path.join(tmp, f"{n}.mappings.properties"), "w") as f:
            f.write(f"addr.{READER}={c['addr']}\ntoken.{READER}\\:\\:{RID}={tok}\n")

    start("gql", [PY, os.path.join(HERE, "mock_sui_gql.py"), "--port", str(GQL), "--cluster", CLUSTER,
                  "--pkg", PKG, "--parent", N["rpi1"]["addr"], "--poa", cse_url("rpi1") + "/", "--epoch", "5"])
    # the sensor's own key, made here (its "device"), registered like a council id-register
    key = os.path.join(tmp, "device-key", f"{DEV}.key")
    ident = json.loads(subprocess.check_output([PY, os.path.join(HERE, "esp32_sim.py"), "--device", DEV,
                                                "--key", key, "--print-identity"]))
    until(lambda: requests.get(f"http://127.0.0.1:{GQL}/__state", timeout=1).ok, 10)
    requests.post(f"http://127.0.0.1:{GQL}/__reg", json={"addr": ident["address"], "cse_id": DEV, "role": 3},
                  timeout=3)
    members = members_file(["rpi1", "rpi2", "rpi3", "rpi4"])      # rpi5 is not onboarded yet
    for n, c in N.items():
        start(f"mqtt-{n}", ["mosquitto", "-p", str(c["mqtt"])])
        start(f"proxy-{n}", [PY, os.path.join(HERE, "tcp_proxy.py"), "--listen", str(c["proxy"]),
                             "--to", f"127.0.0.1:{c['mqtt']}", "--linger", "6"])
        start(f"cse-{n}", [PY, os.path.join(HERE, "mock_cse.py"), "--port", str(c["cse"]),
                           "--chain-url", f"http://127.0.0.1:{CHAIN}",
                           "--mappings", os.path.join(tmp, f"{n}.mappings.properties")])
    # each bridge's ack key, made in its own state dir; only the PUBLIC keys are pinned on the sensor
    ack_keys = os.path.join(tmp, "ack_keys.txt")
    with open(ack_keys, "w") as f:
        for n in N:
            out = json.loads(subprocess.check_output([PY, os.path.join(ROOT, "pi", "om2m_ipe_bridge.py"),
                                                      "-c", bridge_conf(n, members), "--print-ack-key"]))
            f.write(f"{n} {out['apk']}\n")
    for n in N:
        assert until(lambda: requests.get(f"{cse_url(n)}/~/in-cse", headers=HDR, timeout=1).ok, 15), n
        start(f"bridge-{n}", [PY, os.path.join(ROOT, "pi", "om2m_ipe_bridge.py"), "-c", bridge_conf(n, members)])
    for n in N:
        assert until(lambda: "subscribed" in open(procs[f"bridge-{n}"]._log).read(), 15), n

    seeds = ",".join(f"{n}=127.0.0.1:{N[n]['proxy']}" for n in ("rpi1", "rpi2", "rpi3", "rpi4"))
    esp_args = [PY, "-u", os.path.join(HERE, "esp32_sim.py"), "--device", DEV, "--brokers", seeds,
                "--home", "rpi2", "--allow-prefix", "127.0.0.", "--interval", "0.5", "--keepalive", "2",
                "--connect-timeout", "1", "--backoff-base", "1", "--backoff-max", "8",
                "--home-probe", "1", "--home-stable", "4", "--ack-wait", "1", "--drain", "20",
                "--no-ack-failover", "6",
                "--state-file", os.path.join(tmp, "nvs.json"), "--key", key, "--ack-keys", ack_keys]
    start("esp", esp_args)

    # ---- C0 -------------------------------------------------------------------------
    print("\nC0) attach to home, write to the parent")
    st = until(lambda: (latest_status("rpi1") or {}).get("broker") == "rpi2" and latest_status("rpi1"), 15)
    check("sensor attached to its home broker rpi2", st, f"status={st}")
    until(lambda: len(rns("rpi1")) >= 6, 15)
    ae = dump("rpi1")["aes"].get(DEV, {})
    d1 = dump("rpi1")
    check("readings stored on the PARENT's CSE (rpi1), as AE /in-cse/C<device>",
          len(rns("rpi1")) >= 6 and ae.get("ri") == RID, f"{len(rns('rpi1'))} readings, AE ri {ae.get('ri')}")
    check("the AE is DAS-wired on the parent (acp_sui_dac + daci sui-dac)",
          ae.get("acpi") == [d1["acps"]["acp_sui_dac"]] and ae.get("daci") == [d1["dacs"]["sui-dac"]],
          f"acpi={ae.get('acpi')} daci={ae.get('daci')}")
    others = {n: DEV in dump(n)["aes"] for n in ("rpi2", "rpi3", "rpi4", "rpi5")}
    check("no copy on the other nodes (one coherent tree)", not any(others.values()), str(others))
    cin = requests.get(f"{cse_url('rpi1')}/~/in-cse/in-name/{DEV}/data/la", headers=HDR, timeout=3)
    con = json.loads(cin.json()["m2m:cin"]["con"]) if cin.ok else {}
    check("stored reading is attributed to the device's on-chain identity (signer + sig kept)",
          con.get("signer") == ident["address"] and len(con.get("sig", "")) == 128
          and f"signer/{ident['address']}" in ae.get("lbl", []),
          f"signer={con.get('signer')}")
    lbl = [x for x in ae.get("lbl", []) if x.startswith("latest=")]
    check("AE label mirrors the latest reading", lbl and '"seq":' in lbl[0], (lbl or ["-"])[0][:90])

    # ---- C1 -------------------------------------------------------------------------
    print("\nC1) the home broker dies")
    t_kill = time.time()
    stop("mqtt-rpi2", signal.SIGKILL)
    st = until(lambda: (latest_status("rpi1") or {}).get("broker") not in (None, "rpi2")
               and latest_status("rpi1"), 20)
    t_up = time.time() - t_kill
    check("failed over to another broker within 10 s", st and t_up <= 10,
          f"now on {st and st.get('broker')} after {t_up:.1f} s (session {st and st.get('session')})")
    n_before = len(rns("rpi1"))
    time.sleep(3)
    check("readings keep arriving after failover", len(rns("rpi1")) > n_before,
          f"{n_before} -> {len(rns('rpi1'))}")

    # ---- C2 -------------------------------------------------------------------------
    print("\nC2) one-way partition: a late, stale Last Will")
    cur = (latest_status("rpi1") or {}).get("broker")
    old_session = (latest_status("rpi1") or {}).get("session")
    procs[f"proxy-{cur}"].send_signal(signal.SIGHUP)
    st = until(lambda: (latest_status("rpi1") or {}).get("broker") not in (None, cur)
               and latest_status("rpi1"), 25)
    check(f"sensor detected the dead link to {cur} and moved on", st,
          f"now on {st and st.get('broker')} session {st and st.get('session')} (was {old_session})")
    stale = until(lambda: bridge_stats(cur).get("status_stale_ignored", 0) >= 1, 20)
    after = latest_status("rpi1") or {}
    check(f"the Last Will fired late by {cur}'s broker was ignored",
          stale and after.get("state") == "online" and after.get("session") != old_session,
          f"{cur} bridge status_stale_ignored={bridge_stats(cur).get('status_stale_ignored')}, "
          f"stored status={after.get('state')} session {after.get('session')}")
    procs[f"proxy-{cur}"].send_signal(signal.SIGUSR2)

    # ---- C3 -------------------------------------------------------------------------
    print("\nC3) home returns: hysteresis")
    t_back = time.time()
    start("mqtt-rpi2", ["mosquitto", "-p", str(N["rpi2"]["mqtt"])])
    st = until(lambda: (latest_status("rpi1") or {}).get("broker") == "rpi2" and latest_status("rpi1"), 30)
    dt = time.time() - t_back
    check("returned home, but only after the 4 s stability window", st and dt >= 4,
          f"home again after {dt:.1f} s")
    check("left the other broker cleanly (retained presence cleared, no Last Will)",
          "moving back" in esp_log(), "")

    # ---- C4 -------------------------------------------------------------------------
    print("\nC4) the chain names a new parent (rpi3)")
    n1 = len(rns("rpi1"))
    gql_set(parent=N["rpi3"]["addr"], poa=cse_url("rpi3") + "/", epoch=6)
    moved = until(lambda: len(rns("rpi3")) >= 4, 20)
    time.sleep(1.5)
    check("writes moved to rpi3's CSE mid-stream", moved, f"rpi3 now has {len(rns('rpi3'))}")
    d3 = dump("rpi3")["aes"].get(DEV, {})
    check("rpi3 provisioned the device AE DAS-wired with the same ri", d3.get("ri") == RID and d3.get("daci"),
          f"ri={d3.get('ri')} daci={d3.get('daci')}")
    time.sleep(1)
    check("rpi1 no longer receives readings", len(rns("rpi1")) <= n1 + 3, f"{n1} -> {len(rns('rpi1'))}")

    # ---- C5 -------------------------------------------------------------------------
    print("\nC5) the chain cannot be read")
    requests.post(f"http://127.0.0.1:{GQL}/__fail", json={"on": True}, timeout=3)
    n3 = len(rns("rpi3"))
    time.sleep(4)
    check("last known parent kept while GraphQL is down", len(rns("rpi3")) > n3,
          f"rpi3 {n3} -> {len(rns('rpi3'))}")
    requests.post(f"http://127.0.0.1:{GQL}/__fail", json={"on": False}, timeout=3)

    # ---- C6 -------------------------------------------------------------------------
    print("\nC6) a new node joins")
    members_file(["rpi1", "rpi2", "rpi3", "rpi4", "rpi5"])
    os.utime(os.path.join(tmp, "members.conf"))
    learned = until(lambda: "learned rpi5" in esp_log(), 20)
    check("sensor learned rpi5 from the retained om2m/cluster/brokers (no reflash)", learned)
    for n in ("rpi1", "rpi2", "rpi3", "rpi4"):
        stop(f"mqtt-{n}", signal.SIGKILL)
    st = until(lambda: (latest_status("rpi3") or {}).get("broker") == "rpi5" and latest_status("rpi3"), 30)
    check("with rpi1..rpi4's brokers down it attached to rpi5 (never in its seed list)", st,
          f"status={st and st.get('broker')}")
    n3 = len(rns("rpi3"))
    time.sleep(3)
    check("readings flow through rpi5 to the parent", len(rns("rpi3")) > n3, f"{n3} -> {len(rns('rpi3'))}")
    for n in ("rpi1", "rpi2", "rpi3", "rpi4"):
        start(f"mqtt-{n}", ["mosquitto", "-p", str(N[n]["mqtt"])])

    # ---- C7 -------------------------------------------------------------------------
    print("\nC7) protected read through the DAS on the parent")
    base = f"{cse_url('rpi3')}/~/in-cse/in-name/{DEV}"
    before = requests.get(f"http://127.0.0.1:{CHAIN}/state", timeout=3).json()["stats"]
    r = requests.get(base, headers={"X-M2M-Origin": READER, "Accept": "application/json"}, timeout=10)
    lbl = [x for x in (r.json().get("m2m:ae", {}).get("lbl", []) if r.ok else []) if x.startswith("latest=")]
    check("reader RETRIEVE of the AE -> DAS GRANT, carrying the latest reading", r.status_code == 200 and lbl,
          f"HTTP {r.status_code} {(lbl or [''])[0][:70]}")
    r = requests.delete(base, headers={"X-M2M-Origin": READER}, timeout=10)
    after = requests.get(f"http://127.0.0.1:{CHAIN}/state", timeout=3).json()["stats"]
    check("reader DELETE -> DENY, decided by a free simulation (no paid transaction)",
          r.status_code == 403 and after["grant_submitted"] == before["grant_submitted"] + 1
          and after["deny_simulated"] == before["deny_simulated"] + 1,
          f"HTTP {r.status_code}; grants submitted {before['grant_submitted']}->{after['grant_submitted']}, "
          f"denies simulated {before['deny_simulated']}->{after['deny_simulated']}")
    r = requests.get(base, headers={"X-M2M-Origin": "Cstranger", "Accept": "application/json"}, timeout=10)
    log = requests.get(f"{cse_url('rpi3')}/__daslog", timeout=3).json()
    check("unmapped originator -> DENY (No Sui mapping)", r.status_code == 403 and any(
        "No Sui mapping for originator=Cstranger" in l for l in log), f"HTTP {r.status_code}")
    r = requests.get(base + "/data/la", headers={"X-M2M-Origin": READER, "Accept": "application/json"}, timeout=5)
    check("the data container is never referred to the DAS (OM2M limit, documented)", r.status_code == 403,
          f"HTTP {r.status_code}")

    # ---- C9 -------------------------------------------------------------------------
    print("\nC9) the broker is up but its bridge is dead")
    cur = (latest_status("rpi3") or {}).get("broker")
    sys.path.insert(0, os.path.join(ROOT, "pi"))
    import esp_identity as idm
    import paho.mqtt.client as pm
    try:
        atk = pm.Client(pm.CallbackAPIVersion.VERSION2)
    except AttributeError:
        atk = pm.Client()
    rogue_ack = idm.Ed25519PrivateKey.generate()
    forged = [0]

    def forge(c, u, m):              # the attacker "acks" every reading it sees on this broker
        try:
            r = json.loads(m.payload)
        except ValueError:
            return
        if "sig" not in r or "seq" not in r:
            return
        base = {"id": DEV, "seq": r["seq"], "node": cur, "epoch": r.get("epoch")}
        for f in (json.dumps(base), idm.sign_ack(base, rogue_ack),
                  idm.sign_ack(dict(base, id="esp32-other-99"), rogue_ack)):
            c.publish(f"sensors/{DEV}/ack", f, qos=1)
            forged[0] += 1
    atk.on_message = forge
    atk.connect("127.0.0.1", N[cur]["mqtt"])
    atk.subscribe(f"sensors/{DEV}/telemetry")
    atk.loop_start()
    ign0 = esp_log().count("ignored an ack")
    t0 = time.time()
    stop(f"bridge-{cur}")
    st = until(lambda: (latest_status("rpi3") or {}).get("broker") not in (None, cur)
               and (latest_status("rpi3") or {}).get("state") == "online" and latest_status("rpi3"), 30)
    dt = time.time() - t0
    atk.loop_stop()
    atk.disconnect()
    check(f"no acks via {cur} -> failed over (bounded by the 6 s no-ack window)", st and dt <= 6 + 6,
          f"now on {st and st.get('broker')} after {dt:.1f} s")
    check("forged acks on that broker were ignored (they neither held off the failover nor "
          "dropped a reading; C8 checks nothing was lost)",
          forged[0] > 0 and esp_log().count("ignored an ack") > ign0,
          f"{forged[0]} forged acks published")
    start(f"bridge-{cur}", [PY, os.path.join(ROOT, "pi", "om2m_ipe_bridge.py"), "-c",
                            os.path.join(tmp, f"bridge-{cur}.conf")])

    # ---- C10 ------------------------------------------------------------------------
    print("\nC10) per-device identity")
    sys.path.insert(0, os.path.join(ROOT, "pi"))
    import esp_identity as idm
    import paho.mqtt.client as pm
    via = (latest_status("rpi3") or {}).get("broker") or "rpi2"   # the broker the sensor is on
    port = N[via]["mqtt"]
    try:
        cap = pm.Client(pm.CallbackAPIVersion.VERSION2)
    except AttributeError:
        cap = pm.Client()
    got = []
    cap.on_message = lambda c, u, m: got.append(m.payload)
    cap.connect("127.0.0.1", port)
    cap.subscribe(f"sensors/{DEV}/telemetry")
    cap.loop_start()
    pub = lambda payload: cap.publish(f"sensors/{DEV}/telemetry", payload, qos=1).wait_for_publish(3)
    st0 = bridge_stats(via)
    rogue = idm.Ed25519PrivateKey.generate()
    cur_epoch = (latest_status("rpi3") or {}).get("epoch", 1)
    forged = {"v": 2, "id": DEV, "epoch": cur_epoch, "boot": "00000000", "seq": 999999, "ts": 0,
              "temperature": 31.0, "humidity": 50.0}
    pub(idm.sign_obj(forged, rogue))                                     # attacker's own key
    pub(json.dumps(forged, separators=(",", ":")))                       # unsigned
    genuine = until(lambda: got[-1] if got and b'"sig":"' in got[-1] else None, 10)
    if genuine:                                                          # a real reading, altered
        g = json.loads(genuine)
        pub(genuine.replace(f'"seq":{g["seq"]},'.encode(), b'"seq":999998,', 1))
    time.sleep(2.5)
    st1 = bridge_stats(via)
    d = lambda k: st1.get(k, 0) - st0.get(k, 0)
    check("forged (rogue key), unsigned and tampered messages are all rejected",
          d("rejected:auth:device_not_registered") >= 1 and d("rejected:auth:unsigned") >= 1
          and d("rejected:auth:bad_signature") >= 1,
          f"not_registered +{d('rejected:auth:device_not_registered')}, unsigned +{d('rejected:auth:unsigned')}, "
          f"bad_signature +{d('rejected:auth:bad_signature')}")
    check("none of them reached any CSE", not any(x in seen_seqs(n) for n in ("rpi1", "rpi3")
                                                  for x in (999998, 999999)))
    cap.loop_stop()
    cap.disconnect()

    requests.post(f"http://127.0.0.1:{GQL}/__dereg", json={"addr": ident["address"]}, timeout=3)
    time.sleep(3)                                                        # > cache_ttl_s
    n3 = len(rns("rpi3"))
    time.sleep(5)
    rej = sum(bridge_stats(n).get("rejected:auth:device_not_registered", 0) for n in N)
    check("after deregistration (council revoke) no reading is stored",
          len(rns("rpi3")) == n3, f"rpi3 {n3} -> {len(rns('rpi3'))}; bridges rejected {rej} as not registered")
    requests.post(f"http://127.0.0.1:{GQL}/__reg", json={"addr": ident["address"], "cse_id": DEV, "role": 3},
                  timeout=3)
    ok = until(lambda: len(rns("rpi3")) > n3 + 4, 40)
    check("re-registered: readings flow again", ok, f"rpi3 {n3} -> {len(rns('rpi3'))}")

    # ---- C8 -------------------------------------------------------------------------
    print("\nC8) exactly once")
    procs["esp"].send_signal(signal.SIGUSR1)            # stop, drain acks, say goodbye
    procs["esp"].wait(40)
    fin = [l for l in esp_log().splitlines() if "finished:" in l]
    taken = int(fin[-1].split("finished: ")[1].split()[0]) if fin else -1
    time.sleep(2)
    s1, s3 = seen_seqs("rpi1"), seen_seqs("rpi3")
    union = set(s1) | set(s3)
    check("no reading stored twice on any CSE", len(s1) == len(set(s1)) and len(s3) == len(set(s3)),
          f"rpi1 {len(s1)} ({len(set(s1))} distinct), rpi3 {len(s3)} ({len(set(s3))} distinct)")
    check("every reading taken is stored (union across the parent change)", union == set(range(taken)),
          f"{taken} taken, {len(union)} stored, missing {sorted(set(range(taken)) - union)[:10]}, "
          f"{len(set(s1) & set(s3))} in both trees")
    st = {n: bridge_stats(n) for n in N}
    print("  info: per bridge stored / dropped as duplicate (cache + CSE 409): " +
          ", ".join(f"{n} {s.get('stored', 0)}/{s.get('duplicate', 0)}+{s.get('duplicate_cse', 0)}"
                    for n, s in st.items()), flush=True)
    final = latest_status("rpi3") or {}
    check("graceful goodbye recorded offline", final.get("state") == "offline", f"{final}")
    fin_line = fin[-1] if fin else ""
    check("the sensor accepted only signed acks (no reading left unacknowledged, forged ones ignored)",
          " 0 unacknowledged" in fin_line and "forged/unsigned acks ignored" in fin_line, fin_line.strip()[-90:])

    # ---- C11 ------------------------------------------------------------------------
    print("\nC11) durable replay floor (bridge restart, and a bridge with no state)")
    old = genuine                                    # a genuine signed reading of the first epoch
    old_epoch = json.loads(old)["epoch"] if old else -1
    start("esp", esp_args)                           # power cycle: same NVS -> epoch + 1
    new_epoch = old_epoch + 1
    ok = until(lambda: any(r.startswith(f"e{new_epoch}-") for r in rns("rpi3")), 30)
    check("the sensor came back with a new epoch and its readings are stored", ok and old,
          f"epoch {old_epoch} -> {new_epoch}")
    procs["esp"].send_signal(signal.SIGUSR1)
    procs["esp"].wait(40)
    before = len(rns("rpi3"))

    def replay_to(n):
        c = pm.Client(pm.CallbackAPIVersion.VERSION2) if hasattr(pm, "CallbackAPIVersion") else pm.Client()
        c.connect("127.0.0.1", N[n]["mqtt"])
        c.loop_start()
        c.publish(f"sensors/{DEV}/telemetry", old, qos=1).wait_for_publish(3)
        time.sleep(2.5)
        c.loop_stop()
        c.disconnect()

    def restart_bridge(n, wipe=False):
        stop(f"bridge-{n}")
        if wipe:
            shutil.rmtree(os.path.join(tmp, f"state-{n}"), ignore_errors=True)
        with open(procs[f"bridge-{n}"]._log, "a") as f:
            f.write("---- restart ----\n")
        start(f"bridge-{n}", [PY, os.path.join(ROOT, "pi", "om2m_ipe_bridge.py"), "-c",
                              os.path.join(tmp, f"bridge-{n}.conf")])
        until(lambda: "subscribed" in open(procs[f"bridge-{n}"]._log).read().split("---- restart ----")[-1], 15)
        time.sleep(1.5)

    def since_restart(n):
        tail = open(procs[f"bridge-{n}"]._log).read().split("---- restart ----")[-1]
        st = [l for l in tail.splitlines() if " stats {" in l]
        return tail, (json.loads(st[-1].split(" stats ", 1)[1]) if st else {})

    restart_bridge("rpi2")                           # the sensor's home bridge: it saw the new epoch
    replay_to("rpi2")
    tail, st = since_restart("rpi2")
    check("(a) after a restart, the home bridge reloads its floor and rejects the old-epoch replay",
          "replay floor loaded for 1 device" in tail and st.get("rejected:auth:stale_epoch", 0) >= 1,
          f"stale_epoch {st.get('rejected:auth:stale_epoch', 0)}")
    restart_bridge("rpi4", wipe=True)                # no local state at all
    replay_to("rpi4")
    tail, st = since_restart("rpi4")
    check("(b) a bridge with no local state reads the floor off the parent CSE and rejects it too",
          st.get("floor_cse_reads", 0) >= 1 and st.get("rejected:auth:stale_epoch", 0) >= 1,
          f"floor_cse_reads {st.get('floor_cse_reads', 0)}, stale_epoch {st.get('rejected:auth:stale_epoch', 0)}")
    check("nothing from the replays was stored", len(rns("rpi3")) == before,
          f"rpi3 {before} -> {len(rns('rpi3'))} readings")

    for name in list(procs):
        stop(name)
    fails = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(fails)}/{len(results)} checks passed")
    return 1 if fails else 0


if __name__ == "__main__":
    rc = 1
    try:
        rc = main()
    finally:
        for p in procs.values():
            if p.poll() is None:
                p.kill()
    sys.exit(rc)
