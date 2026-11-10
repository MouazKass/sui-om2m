#!/usr/bin/env python3
"""sui-gas-watchdog: keep this node's testnet gas above a floor.

Installed at /usr/local/bin/sui-gas-watchdog and run by sui-gas-watchdog.timer
(every 30 min, randomized). It reads ONLY this node's public address
(sui.node.address) from the plugin config, checks the SUI balance over GraphQL
and, below the threshold, requests one payout from the public testnet faucet
using its v3 proof-of-work API. No key is read, and nothing but the recipient
address is sent to the faucet.

Protocol: https://faucet.sui.io/pow-spec/  (faucet PoW version 1). The
conformance vectors from pow-vectors.json are embedded below and checked with
--self-test, and before every live grind.

Guards (all persisted in STATE_DIR/state.json):
  * at most one payout request per MIN_INTERVAL_H (default 6 h)
  * at most DAILY_CAP POSTs in any rolling 24 h (default 3)
  * backoff after funds_unavailable / not_ready / overloaded (1 h), and after
    any client-side error such as invalid_proof (24 h; needs a human)
  * an uncertain outcome (lost response, payout_status_unknown) is never
    re-ground: the same four fields are resubmitted and any digest is resolved
    on-chain before another payout can be requested.

Every proof (the four submitted fields) and every faucet response is saved
under STATE_DIR before/after submission. Logs go to stdout, i.e. journald.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULTS = {
    "FAUCET": "https://faucet.testnet.sui.io",
    "GRAPHQL": "https://graphql.testnet.sui.io/graphql",
    "NETWORK": "testnet",
    "CONFIG": "/home/user/sui-runtime-config/sui.properties",
    "STATE_DIR": "/var/lib/sui-om2m/faucet",
    "THRESHOLD_SUI": "1.0",
    "MIN_INTERVAL_H": "6",
    "DAILY_CAP": "3",
    "ENABLED": "1",
}
ENV_FILE = "/etc/default/sui-gas-watchdog"

DOMAIN = "sui-faucet-pow/1"
SALT = b"sui-faucet-pow-1"
PARAMS = {"version": 1, "domain": DOMAIN, "algorithm": "argon2d", "argon2Version": 19,
          "memorySize": 8192, "iterations": 1, "parallelism": 1, "hashLength": 32,
          "salt": "sui-faucet-pow-1"}
U64_MAX = (1 << 64) - 1
BACKOFF_SERVICE_S = 3600
BACKOFF_CLIENT_S = 24 * 3600
UNRESOLVED_GIVE_UP_S = 24 * 3600
HTTP_TIMEOUT = 30
UA = "sui-gas-watchdog/1"

# --- conformance vectors (faucet.sui.io/pow-spec/pow-vectors.json) -----------
_VIN = {
    "chainId": "8wWZfv1HjQxjB5ncmC9CQqqRqUMBiEZXnc5FhS9zRe1v",
    "checkpointSeq": "1713342",
    "checkpointDigest": "GzBdc9tbUe3s2PK1iVJcyQBj5TvdX7bJiAHWbhBDYiYb",
    "faucetAddress": "0x949cd75a2485cc18b8258634ffd9b849a687e2e2a0b4c2444a21f007fc79adc4",
    "recipient": "0x1111111111111111111111111111111111111111111111111111111111111111",
}
_RB = "mJ4ZqDXQasy17GTiGfp0/OYAGCR+7reLM5+Gb39YtoAIaPuh1wj+z5J7po+eSze3"
VECTORS = [
    (_RB, "0", "31f6ec0e9169705f6105219eebbbc77420f1d9273d407db5df17b4d090afb92d", 3600324499442593887),
    (_RB, "42", "959c60b9062203b7739fb94aa3577a6173fa36f0cec60e55ce714402b36ffa28", 10780597955806233527),
    (_RB, "201", "0008faf113e0b071f5f9d5d6e1dc9321890ecb7e81059f07dedbd3dec5e902bb", 2527713141239921),
    (_RB, "18446744073709551615", "6f8096ffd12d6c2fe93d8bb12c6b9544e6aa00ed8ee8fcdbe5ebec12000d5dcd", 8034587760699206703),
    ("", "0", "d8430e5471f4fba3c3c67a253f15dc72588d87c364117e1f138e26387050ec60", 15583314891483970467),
]
THRESHOLD_VECTORS = {2: 9223372036854775808, 3: 6148914691236517205, 7: 2635249153387078802,
                     256: 72057594037927936, 724: 25478928278604353, 725: 25443784929254553,
                     1000: 18446744073709551, 11586: 1592158128233173, 281474976710656: 65536}


def log(msg):
    print(msg, flush=True)


# --- PoW primitives ------------------------------------------------------------
def norm_addr(a):
    a = a.strip().lower()
    if not re.fullmatch(r"0x[0-9a-f]{1,64}", a):
        raise ValueError("not a Sui address: %r" % a)
    return "0x" + a[2:].rjust(64, "0")


def norm_u64(s):
    s = str(s)
    if not re.fullmatch(r"0|[1-9][0-9]*", s) or int(s) > U64_MAX:
        raise ValueError("not a canonical u64: %r" % s)
    return s


def threshold_for(difficulty):
    d = int(difficulty)
    if not 2 <= d <= (1 << 48):
        raise ValueError("difficulty out of domain: %d" % d)
    return (1 << 64) // d


def preimage(chain_id, seq, digest, random_b64, faucet_addr, recipient, nonce):
    fields = [DOMAIN, chain_id, norm_u64(seq), digest, random_b64,
              norm_addr(faucet_addr), norm_addr(recipient), norm_u64(nonce)]
    for f in fields:
        if "\n" in f:
            raise ValueError("newline in preimage field")
    return "\n".join(fields).encode("utf-8")


def argon2d(pw):
    from argon2.low_level import Type, hash_secret_raw
    return hash_secret_raw(pw, SALT, time_cost=1, memory_cost=8192, parallelism=1,
                           hash_len=32, type=Type.D, version=19)


def self_test():
    for rb, nonce, want, want_v in VECTORS:
        pi = preimage(_VIN["chainId"], _VIN["checkpointSeq"], _VIN["checkpointDigest"], rb,
                      _VIN["faucetAddress"], _VIN["recipient"], nonce)
        h = argon2d(pi)
        if h.hex() != want or int.from_bytes(h[:8], "big") != want_v:
            raise AssertionError("PoW vector failed for nonce %s: %s" % (nonce, h.hex()))
    for d, t in THRESHOLD_VECTORS.items():
        if threshold_for(d) != t:
            raise AssertionError("threshold vector failed for %d" % d)
    if norm_addr("0x2") != "0x" + "0" * 63 + "2":
        raise AssertionError("address normalization")
    # Spendable balance: the rpi2 case (0.38 SUI coins + 2.0 SUI faucet address balance).
    for src, want in (("auto", 2377761145), ("coin", 377761145), ("address", 2000000000)):
        if spendable_mist(377761145, 2000000000, src) != want:
            raise AssertionError("spendable balance for sui.gas.source=%s" % src)
    return True


# --- HTTP helpers --------------------------------------------------------------
def http_json(url, body=None, method=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method or ("POST" if data else "GET"),
                                 headers={"Content-Type": "application/json", "User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"code": "http_%d" % e.code, "raw": raw[:500]}


def gql(cfg, query):
    st, body = http_json(cfg["GRAPHQL"], {"query": query})
    if st != 200 or body.get("errors"):
        raise RuntimeError("GraphQL error %s: %s" % (st, json.dumps(body)[:300]))
    return body["data"]


def balances_mist(cfg, addr):
    """(coin, address) SUI balances in MIST, read separately.

    The faucet pays into the address balance, which coin-only gas selection
    cannot spend; deciding on totalBalance once reported a node as funded while
    its coins ran dry (2026-11-10)."""
    q = ('{ address(address: "%s") { balance(coinType: "0x2::sui::SUI") '
         '{ coinBalance addressBalance } } }' % addr)
    d = gql(cfg, q)
    b = (d.get("address") or {}).get("balance") or {}
    return int(b.get("coinBalance") or 0), int(b.get("addressBalance") or 0)


def plugin_gas_source(path):
    """sui.gas.source from the node's plugin config: auto (default) | coin | address."""
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("sui.gas.source") and "=" in line:
                    return line.split("=", 1)[1].strip().lower() or "auto"
    except OSError:
        pass
    return "auto"


def spendable_mist(coin, address, gas_source):
    """What the plugin can actually pay gas with. Since the GasPlan bundle
    (2026-11-10) it pays from the address balance unless pinned to coins."""
    if gas_source == "coin":
        return coin
    if gas_source in ("address", "address-balance"):
        return address
    return coin + address


def describe_balance(cfg, addr):
    coin, addrbal = balances_mist(cfg, addr)
    source = plugin_gas_source(cfg["CONFIG"])
    bal = spendable_mist(coin, addrbal, source)
    text = ("coins %.4f SUI, address balance %.4f SUI, spendable %.4f SUI (sui.gas.source=%s)"
            % (coin / 1e9, addrbal / 1e9, bal / 1e9, source))
    return bal, text


def tx_status(cfg, digest):
    """'SUCCESS', 'FAILURE', or None if the network does not know the digest."""
    if not re.fullmatch(r"[1-9A-HJ-NP-Za-km-z]{32,44}", digest or ""):
        return None
    d = gql(cfg, '{ transaction(digest: "%s") { effects { status } } }' % digest)
    t = d.get("transaction")
    return ((t or {}).get("effects") or {}).get("status") if t else None


# --- state ---------------------------------------------------------------------
def now():
    return time.time()


def iso(t=None):
    return dt.datetime.fromtimestamp(t or now(), dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class State:
    def __init__(self, d):
        self.dir = d
        self.path = os.path.join(d, "state.json")
        try:
            with open(self.path) as f:
                self.s = json.load(f)
        except (OSError, ValueError):
            self.s = {}
        self.s.setdefault("posts", [])        # epoch seconds of every POST /v3/gas
        self.s.setdefault("payouts", [])      # epoch seconds of payouts (success or uncertain)
        self.s.setdefault("backoff_until", 0)
        self.s.setdefault("pending", None)    # uncertain submission awaiting resolution

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.s, f, indent=2)
        os.replace(tmp, self.path)

    def record(self, kind, obj):
        name = "%s-%s.json" % (iso().replace(":", ""), kind)
        with open(os.path.join(self.dir, name), "w") as f:
            json.dump(obj, f, indent=2)
        return name


def load_cfg():
    cfg = dict(DEFAULTS)
    try:
        with open(ENV_FILE) as f:
            for line in f:
                m = re.match(r"\s*([A-Z_]+)\s*=\s*\"?([^\"#]*?)\"?\s*(#.*)?$", line)
                if m and m.group(1) in cfg:
                    cfg[m.group(1)] = m.group(2).strip()
    except OSError:
        pass
    for k in cfg:
        if os.environ.get("GW_" + k):
            cfg[k] = os.environ["GW_" + k]
    return cfg


def node_address(path):
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("sui.node.address") and "=" in line:
                return norm_addr(line.split("=", 1)[1])
    raise RuntimeError("sui.node.address not found in %s" % path)


# --- faucet flow ---------------------------------------------------------------
def fetch_challenge(cfg, recipient):
    url = "%s/v3/challenge?%s" % (cfg["FAUCET"], urllib.parse.urlencode({"recipient": recipient}))
    st, ch = http_json(url)
    if st != 200:
        raise RuntimeError("challenge HTTP %s: %s" % (st, json.dumps(ch)[:300]))
    for k, v in PARAMS.items():
        if ch.get(k) != v:
            raise RuntimeError("challenge parameter %s=%r, implemented %r; refusing" % (k, ch.get(k), v))
    if ch.get("network") != cfg["NETWORK"]:
        raise RuntimeError("challenge network %r != %r" % (ch.get("network"), cfg["NETWORK"]))
    if norm_addr(ch["recipient"]) != recipient:
        raise RuntimeError("challenge recipient mismatch")
    thr = threshold_for(ch["difficulty"])
    if str(thr) != str(ch.get("threshold")):
        raise RuntimeError("challenge threshold %s != floor(2^64/%s)=%d" % (ch.get("threshold"), ch["difficulty"], thr))
    return ch, thr


def grind(cfg, recipient, deadline_frac=0.8, max_rounds=4):
    """Solve a fresh challenge; re-fetch if the grind nears its freshness window."""
    for rnd in range(max_rounds):
        ch, thr = fetch_challenge(cfg, recipient)
        started = now()
        budget = float(ch.get("windowSeconds", 60)) * deadline_frac
        nonce = random.getrandbits(62)        # distinct tuples across runs/restarts
        tries = 0
        while now() - started < budget:
            pi = preimage(ch["chainId"], ch["checkpointSeq"], ch["checkpointDigest"], ch["randomBytes"],
                          ch["faucetAddress"], recipient, str(nonce))
            h = argon2d(pi)
            tries += 1
            if int.from_bytes(h[:8], "big") < thr:
                log("solved checkpoint %s after %d hashes in %.1fs (difficulty %s)"
                    % (ch["checkpointSeq"], tries, now() - started, ch["difficulty"]))
                return {"recipient": recipient, "checkpointSeq": norm_u64(ch["checkpointSeq"]),
                        "nonce": str(nonce), "hashHex": h.hex()}, hashlib.sha256(pi).hexdigest()
            nonce = (nonce + 1) & U64_MAX
        log("grind round %d: %d hashes without a solution before the window; fetching a fresh challenge" % (rnd + 1, tries))
    raise RuntimeError("no solution within %d rounds" % max_rounds)


def resolve_digest(cfg, st, digest, label):
    status = tx_status(cfg, digest)
    log("%s: faucet transaction %s status %s" % (label, digest, status or "not found"))
    return status


def submit(cfg, st, proof, pre_sha):
    """POST once; returns (outcome, response). Updates state for every outcome."""
    st.s["posts"].append(now())
    st.s["pending"] = {"proof": proof, "since": now(), "digest": None, "preimageSha256": pre_sha}
    st.save()
    st.record("proof", proof)
    try:
        code, resp = http_json(cfg["FAUCET"] + "/v3/gas", proof)
    except Exception as e:  # lost response: outcome uncertain, keep pending
        log("POST /v3/gas: no response (%s); outcome uncertain, will resubmit the same proof" % e)
        st.s["payouts"].append(now())
        st.save()
        return "uncertain", None
    st.record("response", {"http": code, "body": resp})
    return classify(cfg, st, code, resp, pre_sha), resp


def classify(cfg, st, code, resp, pre_sha):
    c = resp.get("status") if resp.get("status") == "success" else resp.get("code", "unknown")
    digest = resp.get("digest")
    pend = st.s["pending"]
    if c == "success":
        log("payout success: %s MIST, digest %s" % (resp.get("amountMist"), digest))
        st.s["payouts"].append(now())
        st.s["pending"] = None
        st.s["last_success"] = {"at": iso(), "digest": digest, "amountMist": resp.get("amountMist")}
    elif c == "stale_checkpoint":
        log("stale_checkpoint: proof no longer fresh")
        if pend and pend.get("digest"):
            return "stale_with_digest"
        st.s["pending"] = None
    elif c == "already_used":
        if digest:
            status = resolve_digest(cfg, st, digest, "already_used")
            if status:
                st.s["pending"] = None
                if status == "SUCCESS":
                    st.s["last_success"] = {"at": iso(), "digest": digest}
            else:
                pend["digest"] = digest
        else:
            log("already_used without digest: still being processed; will resolve next run")
    elif c == "payout_status_unknown":
        log("payout_status_unknown, digest %s; will resolve before any new payout" % digest)
        if pend is not None:
            pend["digest"] = digest
        st.s["payouts"].append(now())
    elif c == "payout_failed":
        if digest:
            resolve_digest(cfg, st, digest, "payout_failed")
        st.s["pending"] = None
        st.s["backoff_until"] = now() + BACKOFF_SERVICE_S
    elif c in ("funds_unavailable", "not_ready", "overloaded"):
        log("%s: faucet unavailable; backing off %ds" % (c, BACKOFF_SERVICE_S))
        st.s["pending"] = None
        st.s["backoff_until"] = now() + BACKOFF_SERVICE_S
    elif c == "invalid_proof":
        log("invalid_proof: server preimageSha256=%s, ours=%s; client bug, backing off 24h"
            % (resp.get("preimageSha256"), pre_sha))
        st.s["pending"] = None
        st.s["backoff_until"] = now() + BACKOFF_CLIENT_S
    else:  # invalid_request, insufficient_work, internal, unknown codes: non-recoverable
        log("faucet error %s (HTTP %s): %s; backing off 24h" % (c, code, json.dumps(resp)[:300]))
        st.s["pending"] = None
        st.s["backoff_until"] = now() + BACKOFF_CLIENT_S
    st.save()
    return c


def resolve_pending(cfg, st):
    """True if a pending uncertain submission is resolved (or abandoned)."""
    pend = st.s["pending"]
    if not pend:
        return True
    proof = pend["proof"]
    if pend.get("digest"):
        status = resolve_digest(cfg, st, pend["digest"], "pending")
        if status:
            st.s["pending"] = None
            st.save()
            return True
    log("resubmitting the same proof to recover an uncertain outcome")
    try:
        code, resp = http_json(cfg["FAUCET"] + "/v3/gas", proof)
    except Exception as e:
        log("resubmit: no response (%s)" % e)
        code, resp = None, None
    if resp is not None:
        st.record("response", {"http": code, "body": resp, "resubmit": True})
        c = classify(cfg, st, code, resp, pend.get("preimageSha256"))
        if st.s["pending"] is None:
            return True
        if c == "stale_with_digest":
            pass  # digest known but not yet visible; keep waiting
    if now() - pend["since"] > UNRESOLVED_GIVE_UP_S:
        # Sui transactions not visible a day later never executed; the proof
        # itself is long past its window, so it can never pay out.
        log("pending submission unresolved after 24h; treating as not executed")
        st.s["pending"] = None
        st.save()
        return True
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--self-test", action="store_true", help="check the PoW against the spec vectors and exit")
    ap.add_argument("--dry-run", action="store_true", help="check balance and guards; never contact the faucet")
    ap.add_argument("--threshold", type=float, help="override THRESHOLD_SUI for this run")
    ap.add_argument("--status", action="store_true", help="print state and exit")
    a = ap.parse_args()

    self_test()
    if a.self_test:
        log("self-test: %d PoW vectors and %d threshold vectors OK" % (len(VECTORS), len(THRESHOLD_VECTORS)))
        return 0

    cfg = load_cfg()
    os.makedirs(cfg["STATE_DIR"], mode=0o750, exist_ok=True)
    import fcntl
    lockf = open(os.path.join(cfg["STATE_DIR"], ".lock"), "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("another run holds the lock; exiting")
        return 0
    st = State(cfg["STATE_DIR"])
    if a.status:
        print(json.dumps(st.s, indent=2))
        return 0
    if cfg["ENABLED"] != "1":
        log("disabled (ENABLED=%s in %s)" % (cfg["ENABLED"], ENV_FILE))
        return 0

    addr = node_address(cfg["CONFIG"])
    floor = a.threshold if a.threshold is not None else float(cfg["THRESHOLD_SUI"])
    floor_mist = int(round(floor * 1e9))

    if not a.dry_run and not resolve_pending(cfg, st):
        log("an earlier submission is still unresolved; not requesting another payout")
        return 0

    bal, text = describe_balance(cfg, addr)
    log("balance %s: %s, threshold %.4f SUI" % (addr, text, floor))
    if bal >= floor_mist:
        log("above threshold; nothing to do")
        return 0

    t = now()
    st.s["posts"] = [p for p in st.s["posts"] if t - p < 24 * 3600]
    st.s["payouts"] = [p for p in st.s["payouts"] if t - p < 24 * 3600]
    min_interval = float(cfg["MIN_INTERVAL_H"]) * 3600
    if st.s["backoff_until"] > t:
        log("below threshold, but backing off until %s" % iso(st.s["backoff_until"]))
        return 0
    if st.s["payouts"] and t - max(st.s["payouts"]) < min_interval:
        log("below threshold, but last payout request was %s (min interval %sh)"
            % (iso(max(st.s["payouts"])), cfg["MIN_INTERVAL_H"]))
        return 0
    if len(st.s["posts"]) >= int(cfg["DAILY_CAP"]):
        log("below threshold, but daily cap %s reached" % cfg["DAILY_CAP"])
        return 0
    if a.dry_run:
        log("dry-run: would request a faucet payout now")
        return 0

    outcome = None
    for attempt in range(3):  # only stale_checkpoint loops
        if len(st.s["posts"]) >= int(cfg["DAILY_CAP"]):
            log("daily cap reached")
            break
        proof, pre_sha = grind(cfg, addr)
        outcome, _ = submit(cfg, st, proof, pre_sha)
        if outcome != "stale_checkpoint":
            break
    if outcome == "success":
        time.sleep(3)
        log("balance now: %s" % describe_balance(cfg, addr)[1])
    return 0 if outcome in (None, "success", "uncertain", "payout_status_unknown", "already_used") else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        log("error: %s" % e)
        sys.exit(1)
