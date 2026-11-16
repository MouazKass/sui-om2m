#!/usr/bin/env python3
"""
run_replication_e2e.py - losing the parent costs zero readings (fw 2.3 / bridge v2.3).

Same five simulated Pis as run_cluster_e2e.py (real Mosquitto, mock_cse.py, the
REAL bridge), but the bridges run [replication] mode = all (every reading to all
five CSEs, signed ack only on a quorum of 3) and the sensor runs with a durable
flash buffer (--flash-buffer, the model of flash_buffer.h).

  R0  replication       every reading lands on all five CSEs; acked readings are on >= 3
  R1  parent dies       the parent (rpi1: its CSE, broker and bridge) is killed mid-stream,
                        the chain re-elects rpi2: every reading acked before the kill is on
                        the survivors, the sensor fails over, nothing is lost
  R2  no quorum         three CSEs down: nothing is acked (the readings stay in the sensor's
                        flash buffer); the sensor POWER-CYCLES during the outage (new epoch);
                        when quorum returns the old epoch's backlog is sent first, then the
                        new one: nothing lost, no stale-epoch rejection
  R3  catch-up          rpi1 comes back EMPTY (its OM2M lost everything): the leader's
                        reconcile copies the readings it missed
  R4  exactly once      on every CSE every reading is stored once; the union is complete
                        (every seq of every epoch); the sensor has nothing unacked

    python3 sim/run_replication_e2e.py    (needs: mosquitto, paho-mqtt, requests, flask)
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import time

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run_cluster_e2e as h  # noqa: E402  (shared harness: procs, start/stop/until/check, N, ...)

ROOT, PY, N, DEV, RID = h.ROOT, h.PY, h.N, h.DEV, h.RID
ALL = ["rpi1", "rpi2", "rpi3", "rpi4", "rpi5"]


def bridge_conf(n, members):
    path = h.bridge_conf(n, members)
    with open(path, "a") as f:
        f.write("""[replication]
mode = all
quorum = 0
write_timeout_s = 2
down_backoff_min_s = 1
down_backoff_max_s = 4
backfill_interval_s = 1
reconcile_interval_s = 5
""")
    return path


def all_rns(n):
    try:
        return h.rns(n)
    except Exception:
        return None


def holders(rn, nodes=ALL):
    return [n for n in nodes if rn in (all_rns(n) or [])]


def sensor(args_extra, key, ack_keys, fbfile, nvs):
    seeds = ",".join(f"{n}=127.0.0.1:{N[n]['proxy']}" for n in ALL)
    return [PY, "-u", os.path.join(HERE, "esp32_sim.py"), "--device", DEV, "--brokers", seeds,
            "--home", "rpi1", "--allow-prefix", "127.0.0.", "--interval", "0.4", "--keepalive", "2",
            "--connect-timeout", "1", "--backoff-base", "1", "--backoff-max", "4",
            "--home-probe", "1", "--home-stable", "60", "--ack-wait", "1", "--drain", "40",
            "--no-ack-failover", "6", "--state-file", nvs, "--key", key, "--ack-keys", ack_keys,
            "--flash-buffer", fbfile, "--fb-window", "8", "--fb-retry", "3"] + args_extra


def acked_seqs(fbfile):
    try:
        recs = json.load(open(fbfile))["recs"]
    except (OSError, ValueError):
        return set()
    return {(r[0], r[1]) for r in recs if r[3]}


def main():
    if not shutil.which("mosquitto"):
        sys.exit("missing mosquitto")
    tmp = h.tmp
    print(f"logs: {tmp}")
    h.start("chain", [PY, os.path.join(HERE, "chain_sim.py"), "--port", str(h.CHAIN), "--latency-ms", "20"])
    h.until(lambda: requests.get(f"http://127.0.0.1:{h.CHAIN}/state", timeout=1).ok, 10)
    for n, c in N.items():
        h.chain("/admin/register", address=c["addr"], name=n, trust=75)
    h.start("gql", [PY, os.path.join(HERE, "mock_sui_gql.py"), "--port", str(h.GQL), "--cluster", h.CLUSTER,
                    "--pkg", h.PKG, "--parent", N["rpi1"]["addr"], "--poa", h.cse_url("rpi1") + "/",
                    "--epoch", "5"])
    key = os.path.join(tmp, "device-key", f"{DEV}.key")
    ident = json.loads(subprocess.check_output([PY, os.path.join(HERE, "esp32_sim.py"), "--device", DEV,
                                                "--key", key, "--print-identity"]))
    h.until(lambda: requests.get(f"http://127.0.0.1:{h.GQL}/__state", timeout=1).ok, 10)
    requests.post(f"http://127.0.0.1:{h.GQL}/__reg", json={"addr": ident["address"], "cse_id": DEV, "role": 3},
                  timeout=3)
    members = h.members_file(ALL)

    def start_node(n, bridge=True):
        h.start(f"mqtt-{n}", ["mosquitto", "-p", str(N[n]["mqtt"])])
        h.start(f"proxy-{n}", [PY, os.path.join(HERE, "tcp_proxy.py"), "--listen", str(N[n]["proxy"]),
                               "--to", f"127.0.0.1:{N[n]['mqtt']}", "--linger", "2"])
        start_cse(n)
        if bridge:
            start_bridge(n)

    def start_cse(n):
        h.start(f"cse-{n}", [PY, os.path.join(HERE, "mock_cse.py"), "--port", str(N[n]["cse"]),
                             "--chain-url", f"http://127.0.0.1:{h.CHAIN}"])
        assert h.until(lambda: requests.get(f"{h.cse_url(n)}/~/in-cse", headers=h.HDR, timeout=1).ok, 15), n

    def start_bridge(n):
        h.start(f"bridge-{n}", [PY, os.path.join(ROOT, "pi", "om2m_ipe_bridge.py"), "-c", bridge_conf(n, members)])
        assert h.until(lambda: "subscribed" in open(h.procs[f"bridge-{n}"]._log).read(), 15), n

    ack_keys = os.path.join(tmp, "ack_keys.txt")
    with open(ack_keys, "w") as f:
        for n in N:
            out = json.loads(subprocess.check_output([PY, os.path.join(ROOT, "pi", "om2m_ipe_bridge.py"),
                                                      "-c", bridge_conf(n, members), "--print-ack-key"]))
            f.write(f"{n} {out['apk']}\n")
    for n in ALL:
        start_node(n)

    fbfile, nvs = os.path.join(tmp, "flash.json"), os.path.join(tmp, "nvs.json")
    h.start("esp", sensor([], key, ack_keys, fbfile, nvs))

    # ---- R0 -------------------------------------------------------------------------
    print("\nR0) every reading on all five CSEs, ack on quorum")
    h.until(lambda: all(len(all_rns(n) or []) >= 10 for n in ALL), 30)
    counts = {n: len(all_rns(n) or []) for n in ALL}
    h.check("readings replicated to all five CSEs", min(counts.values()) >= 10, str(counts))
    acked = acked_seqs(fbfile)
    bad = [k for k in acked if len(holders(f"e{k[0]}-s{k[1]}")) < 3]
    h.check("every acked reading is held by >= 3 CSEs", acked and not bad, f"{len(acked)} acked, {len(bad)} short")
    st = h.bridge_stats("rpi1")
    h.check("acks come from the quorum path", st.get("stored_quorum", 0) > 0,
            f"stored_quorum={st.get('stored_quorum')} repl_stored={st.get('repl_stored')}")

    # ---- R1 -------------------------------------------------------------------------
    print("\nR1) the parent dies mid-stream")
    acked_before = acked_seqs(fbfile)
    for p in ("bridge-rpi1", "proxy-rpi1", "mqtt-rpi1", "cse-rpi1"):
        h.stop(p, signal.SIGKILL)
    t_kill = time.time()
    time.sleep(2)
    h.gql_set(parent=N["rpi2"]["addr"], poa=h.cse_url("rpi2") + "/", epoch=6)    # re-election
    survivors = ["rpi2", "rpi3", "rpi4", "rpi5"]
    missing = [k for k in acked_before if not holders(f"e{k[0]}-s{k[1]}", survivors)]
    h.check("every reading acked before the kill is on the surviving CSEs", not missing,
            f"{len(acked_before)} acked before, {len(missing)} missing")
    n0 = max(len(all_rns(n) or []) for n in survivors)
    ok = h.until(lambda: max(len(all_rns(n) or []) for n in survivors) >= n0 + 10, 40)
    h.check("the sensor failed over and readings keep arriving", ok,
            f"{n0} -> {max(len(all_rns(n) or []) for n in survivors)} in {time.time() - t_kill:.1f} s")

    # ---- R2 -------------------------------------------------------------------------
    print("\nR2) no quorum: nothing acked, the sensor power-cycles, then quorum returns")
    for n in ("rpi3", "rpi4"):
        h.stop(f"cse-{n}", signal.SIGKILL)        # with rpi1 gone: 2 of 5 CSEs left -> no quorum
    time.sleep(1)
    a_before = len(acked_seqs(fbfile))
    time.sleep(6)
    a_during = len(acked_seqs(fbfile))
    h.check("no ack while fewer than 3 CSEs are up", a_during == a_before, f"{a_before} -> {a_during}")
    h.stop("esp", signal.SIGKILL)                  # power cut: only the flash file survives
    backlog_keys = {(r[0], r[1]) for r in json.load(open(fbfile))["recs"] if not r[3]}
    backlog = len(backlog_keys)
    old_epoch = json.load(open(nvs))["epoch"]
    h.start("esp", sensor([], key, ack_keys, fbfile, nvs))
    time.sleep(4)                                  # the new power-up takes readings, still no quorum
    for n in ("rpi3", "rpi4"):
        start_cse(n)                               # empty (mock CSEs are in memory): they rejoin
    ok = h.until(lambda: backlog_keys <= acked_seqs(fbfile), 60)
    left = sorted(backlog_keys - acked_seqs(fbfile))
    h.check(f"the backlog of {backlog} survived the power cut and was acked after quorum returned",
            backlog > 0 and ok, f"unacked left: {left[:6]}")
    old = [k for k in acked_seqs(fbfile) if k[0] == old_epoch]
    stale = sum(h.bridge_stats(n).get("rejected:auth:stale_epoch", 0) for n in survivors)
    h.check("old epoch delivered before the new one (no stale-epoch rejection)", old and stale == 0,
            f"{len(old)} old-epoch readings acked, stale_epoch rejections {stale}")

    # ---- R3 -------------------------------------------------------------------------
    print("\nR3) rpi1 returns empty; the leader's reconcile fills it")
    start_node("rpi1")
    ref = set(all_rns("rpi2"))
    ok = h.until(lambda: ref <= set(all_rns("rpi1") or []), 60)
    h.check("rpi1 caught up with everything it missed", ok,
            f"rpi1 {len(all_rns('rpi1') or [])} / rpi2 {len(ref)}")
    # stats are logged once a second: give the leader's line time to appear
    h.until(lambda: sum(h.bridge_stats(n).get("repl_reconciled", 0) for n in ALL) > 0, 10)
    rec = sum(h.bridge_stats(n).get("repl_reconciled", 0) for n in ALL)
    h.check("by the reconcile pass (leader = the parent's bridge)", rec > 0, f"repl_reconciled={rec}")

    # ---- R4 -------------------------------------------------------------------------
    print("\nR4) exactly once, nothing lost")
    os.kill(h.procs["esp"].pid, signal.SIGUSR1)                       # finish: drain, then exit
    h.procs["esp"].wait(60)
    time.sleep(6)                                                     # backfill / reconcile settle
    dup = {n: len(r) - len(set(r)) for n in ALL for r in [all_rns(n) or []]}
    h.check("no reading stored twice on any CSE", not any(dup.values()), str(dup))
    union = set().union(*[set(all_rns(n) or []) for n in ALL])
    by_epoch = {}
    for rn in union:
        e, s = rn[1:].split("-s")
        by_epoch.setdefault(int(e), set()).add(int(s))
    gaps = {e: sorted(set(range(max(s) + 1)) - s)[:5] for e, s in by_epoch.items() if set(range(max(s) + 1)) - s}
    h.check("every seq of every epoch is stored (zero loss)", by_epoch and not gaps,
            f"epochs {sorted(by_epoch)}: {[len(v) for _, v in sorted(by_epoch.items())]} readings; gaps {gaps}")
    left = [r[:2] for r in json.load(open(fbfile))["recs"] if not r[3]]
    h.check("the sensor has nothing unacknowledged", not left, str(left[:5]))
    full = [n for n in ALL if set(all_rns(n) or []) == union]
    h.check("all five CSEs converge to the same set", len(full) == 5, f"complete on {full}")

    for name in list(h.procs):
        h.stop(name)
    fails = [r for r in h.results if not r[1]]
    print(f"\n{len(h.results) - len(fails)}/{len(h.results)} checks passed")
    return 1 if fails else 0


if __name__ == "__main__":
    rc = 1
    try:
        rc = main()
    finally:
        for p in h.procs.values():
            if p.poll() is None:
                p.kill()
    sys.exit(rc)
