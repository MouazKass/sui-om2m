#!/usr/bin/env python3
"""
run_e2e.py - single-node end-to-end test of the ESP32 -> Mosquitto -> bridge -> OM2M
path, with no hardware: a real Mosquitto broker, the real bridge, simulated ESP32s
and the oneM2M emulator (mock_cse.py) configured like a v8 testbed node
(in-cse / in-name, provision-das.sh's acp_sui_dac + sui-dac, AE-per-device layout).

These are Hamza AlCharif's original checks, kept scenario for scenario and adapted
to the v2 layout (<device> is a DAC-protected AE with data/ and status/
containers), plus three v2 checks. The cluster scenarios (5 nodes, failover,
parent change, stale Last Will, membership learning, protected reads) are in
run_cluster_e2e.py.

    python3 sim/run_e2e.py            (needs: mosquitto, paho-mqtt, requests, flask)

Scenarios
  1  happy path + bad input   readings stored, malformed/out-of-range/replayed rejected
  2  OM2M restart mid-stream  bridge buffers, re-creates containers, replays, no gaps
  3  ESP32 power loss         broker fires Last Will -> status container says offline
  4  bridge restart           retained status replay does not duplicate status entries
  5  real firmware payloads   output of the actual .ino (host build) is accepted + stored
  6  ACP from birth           every AE/container carries the CURRENT acp_sui_dac and
                              sui-dac (both change on reboot); --check can delete its probe
                              and the CSE rejects a duplicate reading name; without acpi it can't
"""

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
MQTT_PORT, CSE_PORT = 18830, 18282
CSE_ID, CSE_NAME = "in-cse", "in-name"
BASE = f"http://127.0.0.1:{CSE_PORT}"
HDR = {"X-M2M-Origin": "admin:admin", "Accept": "application/json"}

procs = []
results = []
tmp = os.environ.get("E2E_LOGDIR") or tempfile.mkdtemp(prefix="e2e-")
os.makedirs(tmp, exist_ok=True)


def start(name, args, **kw):
    log = open(os.path.join(tmp, f"{name}.log"), "a")
    p = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, **kw)
    p._name, p._log = name, log.name
    procs.append(p)
    return p


def stop(p, sig=signal.SIGTERM, wait=8):
    if p.poll() is None:
        p.send_signal(sig)
        try:
            p.wait(wait)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def wait_until(fn, timeout=15, step=0.25):
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


def dump():
    return requests.get(f"{BASE}/__dump", timeout=3).json()


def cni(path):
    c = dump()["containers"].get(path)
    return c["cni"] if c else None


def data(dev):
    return f"{dev}/data"


def status(dev):
    return f"{dev}/status"


def latest(path, which="la"):
    r = requests.get(f"{BASE}/~/{CSE_ID}/{CSE_NAME}/{path}/{which}", headers=HDR, timeout=3)
    return json.loads(r.json()["m2m:cin"]["con"]) if r.status_code == 200 else None


def start_cse():
    p = start("cse", [PY, os.path.join(HERE, "mock_cse.py"), "--port", str(CSE_PORT),
                      "--cse-id", CSE_ID, "--cse-name", CSE_NAME])
    assert wait_until(lambda: requests.get(f"{BASE}/~/{CSE_ID}", headers=HDR, timeout=1).ok), "CSE up"
    return p


def write_conf(name, **om2m):
    conf = os.path.join(tmp, name)
    extra = "".join(f"{k} = {v}\n" for k, v in om2m.items())
    with open(conf, "w") as f:
        f.write(f"""[mqtt]
host = 127.0.0.1
port = {MQTT_PORT}
client_id = e2e-bridge
[om2m]
base_url = {BASE}
node_label = rpi2
{extra}[bridge]
retry_interval_s = 1
stats_interval_s = 2
log_level = INFO
""")
    return conf


def start_bridge():
    p = start("bridge", [PY, os.path.join(ROOT, "pi", "om2m_ipe_bridge.py"), "-c",
                         write_conf("bridge.conf")])
    assert wait_until(lambda: "subscribed" in open(p._log).read()), "bridge subscribed"
    return p


def sim(device, *extra):
    return start(device, [PY, "-u", os.path.join(HERE, "esp32_sim.py"),
                          "--device", device, "--port", str(MQTT_PORT), *extra])


def sim_lines(p):
    return [l.split(None, 2) for l in open(p._log) if l.startswith("[")]


def last_stats(bridge):
    lines = [l for l in open(bridge._log) if " stats {" in l]
    return json.loads(lines[-1].split(" stats ", 1)[1]) if lines else {}


def main():
    for tool in ("mosquitto", "mosquitto_pub"):
        if not shutil.which(tool):
            sys.exit(f"missing {tool}: sudo apt install mosquitto mosquitto-clients")
    print(f"logs: {tmp}")
    start("mosquitto", ["mosquitto", "-p", str(MQTT_PORT)])
    time.sleep(0.7)
    cse = start_cse()
    bridge = start_bridge()

    # ---- 1 ---------------------------------------------------------------------
    print("\n1) happy path + bad input")
    s = sim("esp32-dht-01", "--interval", "0.15", "--count", "28",
            "--malformed-every", "4", "--range-every", "5", "--replay-every", "7")
    s.wait(30)
    kinds = [k for _, k, _ in sim_lines(s)]
    n_ok = kinds.count("ok") + kinds.count("buffered")   # buffered = taken before attaching, sent later
    n_bad = kinds.count("malformed") + kinds.count("out-of-range")
    n_dup = kinds.count("replay")
    wait_until(lambda: cni(data("esp32-dht-01")) == n_ok)
    got = cni(data("esp32-dht-01"))
    check("only valid readings stored", got == n_ok, f"stored={got} valid_sent={n_ok}")
    st = wait_until(lambda: last_stats(bridge).get("rejected", 0) >= n_bad and last_stats(bridge), 6) or {}
    check("malformed + out-of-range rejected", st.get("rejected") == n_bad,
          f"rejected={st.get('rejected')} expected={n_bad}")
    check("replays dropped as duplicates", st.get("duplicate") == n_dup,
          f"duplicate={st.get('duplicate')} expected={n_dup}")
    la = latest(data("esp32-dht-01"))
    check("latest (la) is the last reading, path /in-cse/in-name/<device>/data",
          la and la["seq"] == n_ok - 1 and la["node"] == "rpi2", f"la.seq={la and la['seq']}")
    stat = latest(status("esp32-dht-01"))
    check("status container tracks online/offline", stat and stat["state"] == "offline"
          and cni(status("esp32-dht-01")) == 2, f"status={stat and stat['state']}")

    # ---- 2 ---------------------------------------------------------------------
    print("\n2) OM2M restarts while the ESP32 keeps sending (like a role switch)")
    acp_before = dump()["acps"]["acp_sui_dac"]
    s2 = sim("esp32-ldr-01", "--no-dht", "--interval", "0.2")
    wait_until(lambda: (cni(data("esp32-ldr-01")) or 0) >= 5, 10)
    stop(cse, signal.SIGKILL)                      # wipes all in-memory resources
    seq_at_kill = len([1 for _, k, _ in sim_lines(s2) if k in ("ok", "buffered")]) - 1
    time.sleep(3)                                  # ~15 readings arrive while OM2M is down
    cse = start_cse()
    acp_after = dump()["acps"]["acp_sui_dac"]
    time.sleep(3)
    stop(s2)
    total_ok = len([1 for _, k, _ in sim_lines(s2) if k in ("ok", "buffered")])
    wait_until(lambda: (latest(data("esp32-ldr-01")) or {}).get("seq") == total_ok - 1, 15)
    la, ol = latest(data("esp32-ldr-01"), "la"), latest(data("esp32-ldr-01"), "ol")
    n = cni(data("esp32-ldr-01"))
    check("containers re-created after wipe", n is not None, f"cni={n}")
    check("readings sent during the outage were replayed",
          ol is not None and ol["seq"] <= seq_at_kill + 1,
          f"oldest_after_restart={ol and ol['seq']} seq_at_kill={seq_at_kill}")
    rns = dump()["containers"][data("esp32-ldr-01")]["rns"]
    # Every reading from the first one replayed after the wipe to the last is
    # present exactly once. (A reading taken before the sensor first attached is
    # re-sent ~1.5 s later and may land in either tree; it is not a gap.)
    import re
    named = [r for r in rns if re.match(r"^e\d+-s\d+$", r)]
    check("every stored reading is named e<epoch>-s<seq> (the CSE-side exactly-once key)",
          rns and len(named) == len(rns), f"{len(named)}/{len(rns)} named, e.g. {rns[:2]}")
    first = ol["seq"] if ol else 0
    seqs = sorted(int(r.split("-s")[1]) for r in named)
    tail = [q for q in seqs if q >= first]
    check("no gaps after recovery", la and ol and tail == list(range(first, la["seq"] + 1)),
          f"seq {first}..{la and la['seq']}, stored={n}, creation order starts {rns[:3]}")
    st = last_stats(bridge)
    check("bridge noticed and re-provisioned", st.get("reprovision", 0) >= 1,
          f"reprovision={st.get('reprovision')} cse_errors={st.get('cse_errors')}")

    # ---- 3 ---------------------------------------------------------------------
    print("\n3) ESP32 loses power (no goodbye)")
    s3 = sim("esp32-dht-02", "--interval", "0.3")
    wait_until(lambda: (latest(status("esp32-dht-02")) or {}).get("state") == "online", 10)
    check("online announced", (latest(status("esp32-dht-02")) or {}).get("state") == "online")
    stop(s3, signal.SIGKILL)
    off = wait_until(lambda: (latest(status("esp32-dht-02")) or {}).get("state") == "offline", 15)
    check("broker Last Will -> status offline", off)

    # ---- 4 ---------------------------------------------------------------------
    print("\n4) bridge restarts (broker replays retained status)")
    status_counts = lambda: {k: v["cni"] for k, v in dump()["containers"].items()
                             if k.endswith("/status")}
    before = status_counts()
    stop(bridge)
    bridge = start_bridge()
    time.sleep(3)
    after = {k: v for k, v in status_counts().items() if k in before}
    check("no duplicate status entries", before == after, f"before={before} after={after}")

    # ---- 5 ---------------------------------------------------------------------
    print("\n5) payloads produced by the real firmware source (host build)")
    fw_out = os.environ.get("FW_PUB", "/tmp/fw_pub.txt")
    if os.path.exists(fw_out):
        lines = [l.rstrip("\n").split("\t") for l in open(fw_out) if l.startswith("PUB")]
        tele = [l for l in lines if l[1].endswith("/telemetry")]
        distinct = {json.loads(l[3])["seq"] for l in tele}
        base_cni = cni(data("esp32-dht-01")) or 0
        for _, topic, retain, payload in lines:
            subprocess.run(["mosquitto_pub", "-p", str(MQTT_PORT), "-t", topic, "-m", payload]
                           + (["-r"] if retain == "1" else []), check=True)
        ok = wait_until(lambda: cni(data("esp32-dht-01")) == base_cni + len(distinct), 15)
        la = latest(data("esp32-dht-01")) or {}
        check("firmware payloads accepted and stored once", ok and la.get("boot") == "a1b2c3d4",
              f"{len(tele)} firmware publishes ({len(distinct)} distinct readings) -> "
              f"{(cni(data('esp32-dht-01')) or 0) - base_cni} stored, la.seq={la.get('seq')}")
    else:
        check("firmware payloads accepted and stored", False, "run the host build first (see README)")

    # ---- 6 ---------------------------------------------------------------------
    print("\n6) ACP attached from birth")
    d = dump()
    cur, dac = d["acps"]["acp_sui_dac"], d["dacs"]["sui-dac"]
    devs = {k: v for k, v in d["aes"].items() if k != "sui-das"}
    bad = {k: v["acpi"] for k, v in list(d["containers"].items()) + list(devs.items()) if v["acpi"] != [cur]}
    bad_dac = {k: v["daci"] for k, v in devs.items() if v["daci"] != [dac]}
    bad_ri = {k: v["ri"] for k, v in devs.items() if v["ri"] != f"/in-cse/C{k}"}
    check("acp_sui_dac ri changed across the OM2M restart", acp_before != acp_after,
          f"{acp_before} -> {acp_after}")
    check("every AE/container carries the current acp_sui_dac", not bad and d["containers"],
          f"{len(d['containers'])} containers, {len(devs)} AEs, wrong acpi: {bad or 'none'}")
    check("every device AE is DAS-wired (daci = current sui-dac), ri /in-cse/C<device>",
          devs and not bad_dac and not bad_ri, f"wrong daci: {bad_dac or 'none'}, wrong ri: {bad_ri or 'none'}")
    bridge_py = os.path.join(ROOT, "pi", "om2m_ipe_bridge.py")
    r = subprocess.run([PY, bridge_py, "-c", write_conf("check.conf"), "--check"],
                       capture_output=True, text=True)
    check("--check creates, writes and deletes its probe", r.returncode == 0,
          (r.stdout.strip().splitlines() or ["?"])[-1])
    check("the CSE rejects a second contentInstance with the same reading name (exactly-once)",
          "duplicate contentInstance name rejected (409)" in r.stdout)
    r = subprocess.run([PY, bridge_py, "-c", write_conf("noacp.conf", protect="false", acp_name=""),
                        "--check"],
                       capture_output=True, text=True)
    check("control: without acpi the probe is locked (why the fix matters)", r.returncode == 3,
          (r.stdout.strip().splitlines() or ["?"])[-1][:90])

    stop(bridge)
    for p in procs:
        stop(p)
    fails = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(fails)}/{len(results)} checks passed")
    return 1 if fails else 0


if __name__ == "__main__":
    rc = 1
    try:
        rc = main()
    finally:
        for p in procs:
            if p.poll() is None:
                p.kill()
    sys.exit(rc)
