#!/usr/bin/env python3
"""
om2m_ipe_bridge.py - MQTT -> oneM2M Interworking Proxy (IPE) for the Sui-OM2M
testbed, cluster edition (v2).

Runs on EVERY Raspberry Pi next to its Mosquitto and OM2M. A sensor may attach
to any Pi's broker (it fails over across the cluster, see DESIGN.md), so any
bridge may receive any device:

  ESP32 --MQTT--> Mosquitto (whichever Pi it is on) --> [this bridge]
        --HTTP/oneM2M--> OM2M of the cluster's CURRENT PARENT (one coherent tree)

Where the data lives
  target = parent (default): the IN-CSE named parent on-chain. The parent and
  its point of access (PoA) are READ from the Sui failover cluster object over
  GraphQL - the same fields FailoverManager publishes. Reads only: this bridge
  never signs or sends a Sui transaction (SY1). If the chain cannot be read,
  the last known parent is kept; if none is known, readings are buffered
  (and, after local_fallback_after_s, written to this node's own CSE so data is
  never silently dropped).
  target = local: this node's own CSE (v1 behaviour).

Resource layout (per device, on the target CSE)
  <AE>        /in-cse/in-name/<device>   ri /in-cse/C<device> (stable: created
              with originator C<device>), acpi = [acp_sui_dac], daci = [sui-dac]
              -> an ordinary RETRIEVE of the AE by any originator the static ACP
              does not grant is decided ON-CHAIN by the Sui DAS through
              DynamicAuthorizationConsultation. A <container> cannot be
              protected that way (OM2M's ContainerController never consults a
              DAS; C2_FINDINGS.md 3.1), which is why v1's flat container layout
              was replaced. The AE label "latest=<json>" mirrors the newest
              reading, so a granted RETRIEVE returns the data itself.
  <container> <device>/data    one contentInstance per reading, rn = e<epoch>-s<seq>
  <container> <device>/status  online/offline history, session-aware
  Both containers carry acp_sui_dac (admin only).

Exactly-once storage across failover
  Every reading carries (epoch, seq). A bridge drops keys it has stored; the
  contentInstance resource name e<epoch>-s<seq> makes the CSE itself reject a
  second copy (409) when two bridges race. Each stored (or already-present)
  reading is acknowledged on sensors/<device>/ack; the sensor re-sends only
  unacknowledged readings.

Per-device identity (identity.mode = require)
  Each sensor signs every telemetry and status message with its own Ed25519
  key (esp_identity.py describes the format). The bridge verifies the
  signature, derives the key's Sui address and accepts the message only if
  that address is registered in the on-chain identity registry as an end
  device (role AE) whose cse_id is this device id. Unsigned, forged,
  unregistered or council-revoked senders are rejected and never acked.
  Stored records keep pk + sig (re-verifiable later) and gain "signer"; the
  AE gets the label signer/<address>. A reading from an older epoch than one
  already authenticated, or older than replay_window_s, is rejected.
  identity.mode = off keeps the v2 behaviour (no checks).

Signed acknowledgements ([ack] sign = true)
  Each ack names (device, epoch, seq) and is signed with this bridge's own
  Ed25519 ack key (state_dir/ack.key, generated here, never copied). The board
  accepts only acks signed by a pinned bridge key (esp_identity.py), so nobody
  on the broker can make it drop an unstored reading or hide a dead bridge.

Durable replay floor (identity.mode = require)
  Per device the bridge keeps (newest authenticated epoch, highest seq in it)
  in state_dir/replay.json (atomic write + fsync), so a restart does not reset
  it. On first contact, and every floor_refresh_s, the floor is also raised
  from the newest reading stored on the target (parent) CSE, so a device that
  failed over from another bridge - or a replay sent to a different bridge -
  meets the same floor. Rejected: an older epoch; in the current epoch, a seq
  more than seq_window below the highest (the board can only resend from its
  RESEND_SLOTS buffer). Within the window the CSE's e<epoch>-s<seq> name
  rejects a second copy (409), so nothing is stored twice.

Session-aware presence
  Status messages carry the sensor's connection session "<epoch>.<n>". A status
  older than the newest one stored is ignored, so the Last Will a broker fires
  late, after the sensor already moved to another broker, cannot mark it offline.

Cluster membership for sensors
  Every bridge publishes, retained on its local broker:
    om2m/cluster/brokers   v1;<ts>;rpi1=10.25.96.200:1883:1,...   (compact, for the ESP32)
    om2m/cluster/members   JSON with labels, hosts, liveness and the parent
  from members_file, re-read when it changes. Liveness is a TCP probe of each
  member's broker. Adding a node = add one line to members_file on every node.

Python 3.9+, needs: paho-mqtt (1.x or 2.x) and requests.
    sudo apt install python3-paho-mqtt python3-requests

Original v1 bridge: Hamza AlCharif (see ../AUTHORS.md). v2: cluster failover,
DAC-protected AE layout, exactly-once storage, session-aware presence.
"""

import argparse
import base64
import collections
import configparser
import json
import logging
import math
import os
import queue
import re
import signal
import socket
import sys
import threading
import time
import uuid

import requests
import paho.mqtt.client as mqtt

log = logging.getLogger("ipe-bridge")

DEVICE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,47}$")
LABEL_RE = re.compile(r"^[a-z0-9-]{1,15}$")
MAX_PAYLOAD_BYTES = 1024
BROKERS_TOPIC = "om2m/cluster/brokers"
MEMBERS_TOPIC = "om2m/cluster/members"

# field -> (min, max). Any reading must contain at least one of these.
MEASUREMENT_RANGES = {
    "temperature": (-40.0, 85.0),     # DHT11 is 0..50 in spec; wider allows DHT22
    "humidity":    (0.0, 100.0),
    "light_raw":   (0, 4095),         # ESP32 12-bit ADC
    "light_pct":   (0, 100),
}
META_RANGES = {
    "rssi":  (-127, 0),
    "up_ms": (0, 2**32 - 1),
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DEFAULTS = {
    "mqtt": {
        "host": "127.0.0.1", "port": "1883", "username": "", "password": "",
        "topic_prefix": "sensors", "client_id": "",
    },
    "om2m": {
        # every testbed node runs the same CSE config (om2m-active, cseType=in-cse)
        "base_url": "http://127.0.0.1:8282", "cse_id": "in-cse", "cse_name": "in-name",
        "originator": "admin:admin", "rvi": "", "ae_api": "N.esp32-ipe",
        # protect = true: each device AE is wired to the Sui DAS (acp_sui_dac +
        # sui-dac, created by provision-das.sh on every node). Never falls back
        # to an unprotected AE: if the wiring is missing, readings are buffered.
        "protect": "true", "dac_acp_name": "acp_sui_dac", "dac_name": "sui-dac",
        # protect = false only: ACP for the resources (empty = none, which
        # locks them; kept for the regression check)
        "acp_name": "acp_admin",
        "data_container": "data", "status_container": "status", "mni": "1000",
        "timeout_s": "5", "node_label": "", "latest_label": "true",
        "latest_label_min_interval_s": "0",
    },
    "cluster": {
        "self": "", "members_file": "", "target": "local",
        "sui_properties": "", "graphql_url": "", "cluster_id": "", "package_original_id": "",
        "parent_poll_s": "10", "local_fallback_after_s": "300",
        "probe_interval_s": "15", "probe_timeout_s": "1.0", "announce_interval_s": "30",
        "announce_refresh_s": "300",
    },
    "identity": {
        # off: no device authentication (v2). require: every message must be
        # signed by a device key registered on-chain (role AE, cse_id = device).
        "mode": "off", "registry_id": "", "graphql_url": "",
        "cache_ttl_s": "60", "negative_ttl_s": "15", "max_stale_s": "300",
        "replay_window_s": "3600",
        # durable replay floor: seq_window must exceed the board's RESEND_SLOTS
        # (64) and stay below om2m.mni (1000), so the CSE 409 covers the window
        "seq_window": "256", "floor_refresh_s": "60",
    },
    "ack": {
        # sign = true: every ack is signed with the bridge's ack key
        # (key_file, default <state_dir>/ack.key, created 0600 on first start)
        "sign": "false", "key_file": "",
    },
    "bridge": {
        "queue_max": "2000", "retry_interval_s": "3", "stats_interval_s": "60",
        "log_level": "INFO", "dedupe_window": "4096",
        # durable state (replay floor, ack key). Empty = in memory only.
        "state_dir": "",
    },
}


def load_config(path):
    cp = configparser.ConfigParser()
    cp.read_dict(DEFAULTS)
    if path:
        if not cp.read(path):
            raise SystemExit(f"config file not found: {path}")
    return cp


def truthy(v):
    return str(v).strip().lower() in ("1", "true", "yes", "on")


def read_properties(path):
    """Minimal java.util.Properties reader (key=value, # comments)."""
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line[0] in "#!" or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    except OSError as e:
        log.warning("cannot read %s: %s", path, e)
    return out


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
class Rejected(Exception):
    """Payload is not a valid reading. The message is the reason code."""


def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _uint(v, hi=2**32):
    return isinstance(v, int) and not isinstance(v, bool) and 0 <= v < hi


def _load(raw):
    if len(raw) > MAX_PAYLOAD_BYTES:
        raise Rejected("too_large")
    try:
        msg = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise Rejected("not_json")
    if not isinstance(msg, dict):
        raise Rejected("not_object")
    return msg


def validate_telemetry(device, raw: bytes) -> dict:
    msg = _load(raw)
    v = msg.get("v")
    if v not in (1, 2):
        raise Rejected("bad_version")
    if msg.get("id") != device:
        raise Rejected("id_topic_mismatch")
    if not _uint(msg.get("seq")):
        raise Rejected("bad_seq")
    boot = msg.get("boot")
    if not (isinstance(boot, str) and 0 < len(boot) <= 16):
        raise Rejected("bad_boot")
    if v == 2 and not (_uint(msg.get("epoch")) and msg["epoch"] >= 1):
        raise Rejected("bad_epoch")
    ts = msg.get("ts", 0)
    if not _uint(ts, 2**63):
        raise Rejected("bad_ts")
    found = 0
    for field, (lo, hi) in MEASUREMENT_RANGES.items():
        if field in msg:
            if not _num(msg[field]):
                raise Rejected(f"bad_{field}")
            if not lo <= msg[field] <= hi:
                raise Rejected(f"range_{field}")
            found += 1
    for field, (lo, hi) in META_RANGES.items():
        if field in msg and (not _num(msg[field]) or not lo <= msg[field] <= hi):
            raise Rejected(f"bad_{field}")
    if found == 0:
        raise Rejected("no_measurement")
    return msg


SESSION_RE = re.compile(r"^(\d{1,10})\.(\d{1,10})$")


def session_key(s):
    """'<epoch>.<n>' -> (epoch, n); None if absent/malformed."""
    m = SESSION_RE.match(s) if isinstance(s, str) else None
    return (int(m.group(1)), int(m.group(2))) if m else None


def validate_status(device, raw: bytes) -> dict:
    msg = _load(raw)
    if msg.get("state") not in ("online", "offline"):
        raise Rejected("bad_status")
    if msg.get("id") != device:
        raise Rejected("id_topic_mismatch")
    if "session" in msg and session_key(msg["session"]) is None:
        raise Rejected("bad_session")
    return msg


def reading_key(msg):
    """Dedupe identity of a reading, and the CIN resource name derived from it."""
    if msg.get("v") == 2:
        return ("e", msg["epoch"], msg["seq"]), f"e{msg['epoch']}-s{msg['seq']}"
    return ("b", msg["boot"], msg["seq"]), f"b{msg['boot']}-s{msg['seq']}"


# ---------------------------------------------------------------------------
# Cluster membership + liveness
# ---------------------------------------------------------------------------
class Member:
    __slots__ = ("label", "host", "port", "cse_url", "addr", "alive")

    def __init__(self, label, host, port, cse_url, addr):
        self.label, self.host, self.port = label, host, int(port)
        self.cse_url, self.addr, self.alive = cse_url.rstrip("/"), (addr or "").lower(), False


def parse_members(text):
    """members_file: '<label> <host> <mqtt-port> <cse-url> [sui-address]' per line."""
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        f = line.split()
        if len(f) < 4 or not LABEL_RE.match(f[0]) or not f[2].isdigit():
            raise ValueError(f"members line {n}: '{line}'")
        out.append(Member(f[0], f[1], f[2], f[3], f[4] if len(f) > 4 else ""))
    return out


def brokers_payload(members, ts=None):
    """The compact retained payload the firmware's cluster.h parses."""
    ts = int(time.time()) if ts is None else ts
    return f"v1;{ts};" + ",".join(f"{m.label}={m.host}:{m.port}:{1 if m.alive else 0}" for m in members)


class Cluster:
    def __init__(self, cfg):
        c = cfg["cluster"]
        self.path = c["members_file"].strip()
        self.self_label = c["self"].strip()
        self.probe_s = float(c["probe_interval_s"])
        self.probe_timeout = float(c["probe_timeout_s"])
        self.members = []
        self._mtime = None
        self.lock = threading.Lock()
        self.reload()

    def reload(self):
        if not self.path:
            return False
        try:
            mt = os.path.getmtime(self.path)
        except OSError:
            return False
        if mt == self._mtime:
            return False
        try:
            with open(self.path, encoding="utf-8") as f:
                new = parse_members(f.read())
        except (OSError, ValueError) as e:
            log.error("members file %s not loaded: %s", self.path, e)
            return False
        with self.lock:
            old = {m.label: m.alive for m in self.members}
            for m in new:
                m.alive = old.get(m.label, False)
            self.members = new
            self._mtime = mt
        log.info("cluster members: %s", ", ".join(f"{m.label}@{m.host}:{m.port}" for m in new))
        return True

    def probe_once(self, local_mqtt_ok):
        with self.lock:
            ms = list(self.members)
        for m in ms:
            if m.label == self.self_label:
                m.alive = local_mqtt_ok
                continue
            try:
                with socket.create_connection((m.host, m.port), timeout=self.probe_timeout):
                    m.alive = True
            except OSError:
                m.alive = False

    def by_addr(self, addr):
        a = (addr or "").lower()
        with self.lock:
            return next((m for m in self.members if a and m.addr == a), None)

    def snapshot(self):
        with self.lock:
            return list(self.members)


# ---------------------------------------------------------------------------
# Parent resolution (Sui reads only)
# ---------------------------------------------------------------------------
Q_OBJECT = "query($id:SuiAddress!){ object(address:$id){ asMoveObject { contents { json } } } }"
Q_DF = ("query($id:SuiAddress!,$type:String!,$bcs:Base64!){ object(address:$id){"
        " dynamicField(name:{type:$type, bcs:$bcs}){ value { __typename"
        " ... on MoveValue { json } ... on MoveObject { contents { json } } } } } }")
UNIT_KEY_BCS = "AA=="     # ParentPoaKey / ParentPoaOwnerKey are unit structs


class ParentResolver:
    """Tracks the cluster's current parent and its CSE base URL."""

    def __init__(self, cfg, cluster):
        c = cfg["cluster"]
        self.mode = c["target"].strip().lower()
        if self.mode not in ("parent", "local"):
            raise SystemExit("cluster.target must be 'parent' or 'local'")
        self.local = cfg["om2m"]["base_url"].rstrip("/")
        props = read_properties(c["sui_properties"]) if c["sui_properties"].strip() else {}
        self.gql = c["graphql_url"].strip() or props.get("sui.graphql.url", "")
        self.cluster_id = c["cluster_id"].strip() or props.get("sui.failover.cluster.id", "")
        self.pkg = (c["package_original_id"].strip() or props.get("sui.package.original.id")
                    or props.get("sui.package.id", ""))
        self.poll_s = float(c["parent_poll_s"])
        self.fallback_after = float(c["local_fallback_after_s"])
        self.cluster = cluster
        self.http = requests.Session()
        self.lock = threading.Lock()
        self.parent = None          # dict(addr, epoch, base, poa, label)
        self.since_no_parent = time.time()
        self.last_error = None
        self.changes = 0
        if self.mode == "parent" and not (self.gql and self.cluster_id and self.pkg):
            raise SystemExit("cluster.target=parent needs graphql_url, cluster_id and "
                             "package_original_id (or sui_properties pointing at sui.properties)")

    def _q(self, query, variables):
        r = self.http.post(self.gql, json={"query": query, "variables": variables}, timeout=10)
        r.raise_for_status()
        d = r.json()
        if d.get("errors"):
            raise RuntimeError(str(d["errors"])[:200])
        return d.get("data") or {}

    def _df(self, type_name):
        d = self._q(Q_DF, {"id": self.cluster_id, "type": type_name, "bcs": UNIT_KEY_BCS})
        df = ((d.get("object") or {}).get("dynamicField") or {})
        val = df.get("value") or {}
        if val.get("__typename") == "MoveValue":
            return val.get("json")
        if val.get("__typename") == "MoveObject":
            return (val.get("contents") or {}).get("json")
        return None

    def poll_once(self):
        if self.mode != "parent":
            return
        try:
            obj = self._q(Q_OBJECT, {"id": self.cluster_id})
            j = ((((obj.get("object") or {}).get("asMoveObject") or {}).get("contents") or {})
                 .get("json") or {})
            addr = (j.get("current_parent") or "").lower()
            epoch = int(j.get("epoch", 0))
            if not addr:
                raise RuntimeError("cluster object has no current_parent")
            poa_raw = self._df(f"{self.pkg}::failover::ParentPoaKey")
            owner = self._df(f"{self.pkg}::failover::ParentPoaOwnerKey")   # absent on v8
            poa = None
            if isinstance(poa_raw, str) and poa_raw:
                try:
                    poa = base64.b64decode(poa_raw).decode("utf-8")
                except Exception:
                    poa = poa_raw          # already a string
            if poa and owner and str(owner).lower() != addr:
                log.warning("ignoring PoA %s: published by %s, parent is %s", poa, owner, addr)
                poa = None
            m = self.cluster.by_addr(addr) if self.cluster else None
            base = (poa or "").rstrip("/") or (m.cse_url if m else "")
            if not base:
                raise RuntimeError(f"parent {addr} has no PoA and is not in members_file")
            new = {"addr": addr, "epoch": epoch, "base": base, "poa": poa,
                   "label": m.label if m else addr[:10]}
            with self.lock:
                old = self.parent
                self.parent, self.last_error = new, None
            if not old or old["base"] != new["base"] or old["addr"] != new["addr"]:
                self.changes += 1
                log.info("cluster parent: %s (epoch %d) -> writing to %s", new["label"], epoch, base)
        except Exception as e:      # keep the last known parent (sticky)
            with self.lock:
                self.last_error = f"{type(e).__name__}: {e}"
                stale = self.parent
            log.warning("parent lookup failed (%s); %s", self.last_error,
                        f"keeping {stale['label']}" if stale else "no parent known yet")

    def target(self):
        """Base URL to write to, or None (buffer)."""
        if self.mode == "local":
            return self.local
        with self.lock:
            p = self.parent
        if p:
            self.since_no_parent = time.time()
            return p["base"]
        if self.fallback_after > 0 and time.time() - self.since_no_parent >= self.fallback_after:
            return self.local
        return None

    def describe(self):
        with self.lock:
            return dict(self.parent) if self.parent else None


# ---------------------------------------------------------------------------
# oneM2M HTTP client
# ---------------------------------------------------------------------------
class CseUnavailable(Exception):
    """Transient: CSE unreachable, timed out, or 5xx. Retry later."""


class ResourceGone(Exception):
    """404 on a resource we created earlier: CSE lost its state. Re-provision."""


class CseRejected(Exception):
    """Permanent 4xx (other than 404/409) for this request. Do not retry."""


class Duplicate(Exception):
    """409 on a contentInstance name: this reading is already stored."""


class OneM2MClient:
    def __init__(self, cfg, base):
        o = cfg["om2m"]
        self.base = base.rstrip("/")
        self.cse_id = o["cse_id"].strip("/")
        self.cse_name = o["cse_name"].strip("/")
        self.origin = o["originator"]
        self.rvi = o["rvi"].strip()
        self.timeout = float(o["timeout_s"])
        self.http = requests.Session()

    def cse_root(self):
        return f"{self.base}/~/{self.cse_id}"

    def hier(self, *names):
        return "/".join([f"{self.base}/~/{self.cse_id}/{self.cse_name}", *names])

    def url_for_ri(self, ri):
        if ri.startswith("/"):
            return f"{self.base}/~{ri}"
        return f"{self.base}/~/{self.cse_id}/{ri}"

    def _headers(self, ty=None, origin=None, body=False):
        h = {"X-M2M-Origin": origin or self.origin, "X-M2M-RI": uuid.uuid4().hex[:16],
             "Accept": "application/json"}
        if self.rvi:
            h["X-M2M-RVI"] = self.rvi
        if ty is not None:
            h["Content-Type"] = f"application/json;ty={ty}"
        elif body:
            h["Content-Type"] = "application/json"
        return h

    def _request(self, method, url, ty=None, body=None, origin=None):
        try:
            r = self.http.request(method, url, headers=self._headers(ty, origin, body is not None),
                                  data=json.dumps(body) if body is not None else None,
                                  timeout=self.timeout)
        except requests.RequestException as e:
            raise CseUnavailable(f"{type(e).__name__}: {e}") from None
        if r.status_code >= 500:
            raise CseUnavailable(f"HTTP {r.status_code} {r.text[:200]}")
        return r

    @staticmethod
    def _resource(resp):
        try:
            data = resp.json()
        except ValueError:
            return {}
        if isinstance(data, dict):
            for v in data.values():
                if isinstance(v, dict):
                    return v
        return {}

    def create(self, parent_url, ty, key, attrs, lookup_url, origin=None):
        """Create a resource; on 409 look it up instead. Returns (ri, created)."""
        r = self._request("POST", parent_url, ty=ty, body={key: attrs}, origin=origin)
        if r.status_code == 201:
            ri = self._resource(r).get("ri")
            if not ri:
                raise CseRejected(f"201 without ri: {r.text[:200]}")
            return ri, True
        if r.status_code == 409:
            g = self._request("GET", lookup_url)
            if g.status_code == 200 and self._resource(g).get("ri"):
                return self._resource(g)["ri"], False
            raise CseRejected(f"exists but lookup failed: GET {lookup_url} -> {g.status_code}")
        if r.status_code == 404:
            raise ResourceGone(f"parent missing: {parent_url}")
        raise CseRejected(f"POST {parent_url} -> {r.status_code} {r.text[:200]}")

    def add_instance(self, container_ri, content: dict, rn=None):
        url = self.url_for_ri(container_ri)
        cin = {"cnf": "application/json:0",
               "con": json.dumps(content, separators=(",", ":"), sort_keys=True)}
        if rn:
            cin["rn"] = rn
        r = self._request("POST", url, ty=4, body={"m2m:cin": cin})
        if r.status_code == 201:
            return self._resource(r).get("ri")
        if r.status_code == 409 and rn:
            raise Duplicate(rn)
        if r.status_code == 404:
            raise ResourceGone(f"container gone: {container_ri}")
        raise CseRejected(f"CIN -> {r.status_code} {r.text[:200]}")

    def update(self, ri, key, attrs):
        r = self._request("PUT", self.url_for_ri(ri), body={key: attrs})
        if r.status_code == 404:
            raise ResourceGone(f"gone: {ri}")
        return r.status_code

    def find_ri(self, *names):
        r = self._request("GET", self.hier(*names))
        return self._resource(r).get("ri") if r.status_code == 200 else None

    def delete(self, ri):
        return self._request("DELETE", self.url_for_ri(ri)).status_code

    def delete_ae(self, ri):
        """Delete an AE that may carry daci. OM2M 1.x (EclipseLink) keeps a
        deleted AE in the cached <dynamicAuthorizationConsultation>'s AE list,
        so the NEXT AE created with that daci fails with HTTP 500 (FK
        AE_DAC_JOIN_AE_ID, seen live 2026-11-10) until om2m-active restarts.
        Unlinking daci first (UPDATE daci=[]) keeps the cache consistent."""
        self._request("PUT", self.url_for_ri(ri), body={"m2m:ae": {"daci": []}})
        return self.delete(ri)

    def latest_content(self, container_ri):
        return self.latest_at(self.url_for_ri(container_ri))

    def latest_at(self, container_url):
        r = self._request("GET", container_url + "/la")
        if r.status_code != 200:
            return None
        con = self._resource(r).get("con")
        try:
            return json.loads(con) if isinstance(con, str) else None
        except ValueError:
            return None


# ---------------------------------------------------------------------------
# Bridge
# ---------------------------------------------------------------------------
class Placement:
    """Where one device lives on one target CSE."""
    __slots__ = ("ae_ri", "cnt_ri", "provisioned_once")

    def __init__(self):
        self.ae_ri, self.cnt_ri, self.provisioned_once = None, {}, False


class Device:
    def __init__(self, name, window):
        self.name = name
        self.recent = collections.OrderedDict()     # reading key -> None (stored keys)
        self.window = window
        self.places = {}                             # target base -> Placement
        self.last_state = None
        self.last_session = None                     # newest session key seen here
        self.last_label_at = 0.0
        self.signer = None                           # on-chain address of the device key
        self.max_epoch = 0                           # newest authenticated epoch

    def labels(self):
        lbl = ["type/esp32", f"device/{self.name}"]
        if self.signer:
            lbl.append(f"signer/{self.signer}")
        return lbl

    def seen(self, key):
        return key in self.recent

    def remember(self, key):
        self.recent[key] = None
        while len(self.recent) > self.window:
            self.recent.popitem(last=False)

    def place(self, base):
        return self.places.setdefault(base, Placement())


class ReplayState:
    """Per-device replay floor {device: {"epoch": E, "high": S}}, kept durably.

    save() writes a temp file, fsyncs it, renames it over replay.json and
    fsyncs the directory, so a crash leaves either the old or the new file.
    An epoch increase is saved at once; seq progress at most once a second.
    """

    def __init__(self, path):
        self.path = path
        self.data = {}
        self.dirty = False
        self.checked = {}                           # device -> time of the last CSE floor read
        if path and os.path.exists(path):
            try:
                with open(path) as f:
                    d = json.load(f)
                self.data = {k: {"epoch": int(v["epoch"]), "high": int(v["high"])}
                             for k, v in d.get("devices", {}).items()}
                log.info("replay floor loaded for %d device(s) from %s", len(self.data), path)
            except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
                # kept for inspection; the floor then comes from the CSE
                log.error("cannot read %s (%s); moved aside, floors come from the CSE", path, e)
                os.replace(path, path + ".corrupt")
                self.data = {}

    def get(self, device):
        return self.data.get(device)

    def raise_to(self, device, epoch, seq):
        """Raise the floor; -> True if the epoch went up (saved immediately)."""
        cur = self.data.get(device)
        if cur is None or epoch > cur["epoch"]:
            self.data[device] = {"epoch": epoch, "high": seq}
            self.dirty = True
            self.save()
            return True
        if epoch == cur["epoch"] and seq > cur["high"]:
            cur["high"] = seq
            self.dirty = True
        return False

    def save(self):
        if not self.path:
            self.dirty = False
            return
        if not self.dirty:
            return
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"v": 1, "ts": int(time.time()), "devices": self.data}, f, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)
        try:
            fd = os.open(os.path.dirname(self.path) or ".", os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        except OSError:
            pass                                    # directory fsync unsupported (non-POSIX)
        self.dirty = False


class Bridge:
    def __init__(self, cfg):
        self.cfg = cfg
        o, b, m = cfg["om2m"], cfg["bridge"], cfg["mqtt"]
        self.api = o["ae_api"]
        self.cnt_data = o["data_container"]
        self.cnt_status = o["status_container"]
        self.mni = int(o["mni"])
        self.protect = truthy(o["protect"])
        self.dac_acp_name = o["dac_acp_name"].strip()
        self.dac_name = o["dac_name"].strip()
        self.acp_name = o["acp_name"].strip()
        self.latest_label = truthy(o["latest_label"])
        self.latest_min_s = float(o["latest_label_min_interval_s"])
        self.node_label = o["node_label"]
        self.prefix = m["topic_prefix"].strip("/")
        self.queue_max = int(b["queue_max"])
        self.retry_s = float(b["retry_interval_s"])
        self.stats_s = float(b["stats_interval_s"])
        self.window = int(b["dedupe_window"])
        c = cfg["cluster"]
        self.announce_s = float(c["announce_interval_s"])
        self.refresh_s = float(c["announce_refresh_s"])

        self.cluster = Cluster(cfg)
        self.resolver = ParentResolver(cfg, self.cluster)
        self.clients = {}
        self.inbox = queue.Queue()
        self.pending = collections.deque()
        self.devices = {}
        self.stats = collections.Counter()
        self.stop_evt = threading.Event()
        self.cse_ok = True
        self.mqtt = None
        self.mqtt_ok = False
        self._last_announce = ("", 0.0)
        self.state_dir = b["state_dir"].strip()
        if self.state_dir:
            os.makedirs(self.state_dir, mode=0o700, exist_ok=True)
        self._init_ack(cfg)
        self._init_identity(cfg)

    def _init_ack(self, cfg):
        a = cfg["ack"]
        self.ack_key = None
        self.ack_pk = ""
        if not truthy(a["sign"]):
            log.warning("ack.sign = false: acks are unsigned (any broker client can forge them)")
            return
        path = a["key_file"].strip() or (os.path.join(self.state_dir, "ack.key") if self.state_dir else "")
        if not path:
            raise SystemExit("ack.sign = true needs ack.key_file or bridge.state_dir")
        import esp_identity
        self.ack_key = esp_identity.load_or_create_key(path)
        self.ack_pk = esp_identity.public_bytes(self.ack_key).hex()
        self._sign_ack = esp_identity.sign_ack
        log.info("acks signed with this bridge's key %s (%s)", self.ack_pk, path)

    def _init_identity(self, cfg):
        i = cfg["identity"]
        self.id_mode = i["mode"].strip().lower()
        if self.id_mode not in ("off", "require"):
            raise SystemExit("identity.mode must be 'off' or 'require'")
        self.registry = None
        self.replay_window_s = float(i["replay_window_s"])
        self.seq_window = int(i["seq_window"])
        self.floor_refresh_s = float(i["floor_refresh_s"])
        self.replay = ReplayState(os.path.join(self.state_dir, "replay.json") if self.state_dir else "")
        if self.id_mode == "off":
            log.warning("identity.mode = off: device messages are NOT authenticated")
            return
        import esp_identity                      # needs python3-cryptography
        self._idmod = esp_identity
        c = cfg["cluster"]
        props = read_properties(c["sui_properties"]) if c["sui_properties"].strip() else {}
        reg = i["registry_id"].strip() or props.get("sui.identity.registry.id", "")
        gql = (i["graphql_url"].strip() or c["graphql_url"].strip()
               or props.get("sui.graphql.url", ""))
        if not (reg and gql):
            raise SystemExit("identity.mode = require needs identity.registry_id (or "
                             "sui.identity.registry.id in sui_properties) and a graphql_url")
        http = requests.Session()

        def post(query, variables):
            r = http.post(gql, json={"query": query, "variables": variables}, timeout=10)
            r.raise_for_status()
            d = r.json()
            if d.get("errors"):
                raise RuntimeError(str(d["errors"])[:200])
            return d.get("data") or {}
        self.registry = esp_identity.DeviceRegistry(
            post, reg, ttl_s=float(i["cache_ttl_s"]), negative_ttl_s=float(i["negative_ttl_s"]),
            max_stale_s=float(i["max_stale_s"]))
        log.info("device identity required: registry %s via %s", reg, gql)

    def authenticate(self, device, kind, payload, msg, rx_time):
        """identity.mode = require: -> signer address, or raise Rejected('auth:<reason>')."""
        idm = self._idmod
        try:
            pk = idm.verify_message(payload, msg)
            addr = self.registry.check(device, pk)
        except idm.IdentityError as e:
            raise Rejected(f"auth:{e}")
        dev = self.device(device)
        if kind == "telemetry" and msg.get("v") == 2:
            fl = self.floor(device, rx_time)
            e, sq = msg["epoch"], msg["seq"]
            if fl and e < fl["epoch"]:
                raise Rejected("auth:stale_epoch")
            if fl and e == fl["epoch"] and sq + self.seq_window < fl["high"]:
                raise Rejected("auth:stale_seq")
            ts = msg.get("ts", 0)
            if ts and ts < rx_time - self.replay_window_s:
                raise Rejected("auth:stale_reading")
            if self.replay.raise_to(device, e, sq):
                log.info("%s: replay floor now epoch %d", device, e)
            dev.max_epoch = max(dev.max_epoch, e)
        if dev.signer != addr:
            if dev.signer:
                log.warning("%s: signing key changed %s -> %s", device, dev.signer, addr)
            dev.signer = addr
            dev.places.clear()                   # re-provision: AE label carries the signer
        return addr

    def floor(self, device, now):
        """Replay floor for a device: the durable local one, raised from the
        newest reading on the target CSE on first contact / every floor_refresh_s."""
        last = self.replay.checked.get(device, 0.0)
        if now - last >= self.floor_refresh_s:
            base = self.resolver.target()
            if base is not None:
                cse = self.cse(base)
                try:
                    la = cse.latest_at(cse.hier(device, self.cnt_data))
                    self.replay.checked[device] = now
                    self.stats["floor_cse_reads"] += 1
                    if la and _uint(la.get("epoch")) and _uint(la.get("seq")):
                        if self.replay.raise_to(device, la["epoch"], la["seq"]):
                            log.info("%s: replay floor raised from %s to epoch %d seq %d",
                                     device, base, la["epoch"], la["seq"])
                except CseUnavailable as e:
                    # keep the local floor; try again in 5 s
                    self.replay.checked[device] = now - self.floor_refresh_s + 5
                    log.warning("%s: CSE floor unavailable (%s); using the local floor", device, e)
        return self.replay.get(device)

    def cse(self, base):
        if base not in self.clients:
            self.clients[base] = OneM2MClient(self.cfg, base)
        return self.clients[base]

    def device(self, name):
        if name not in self.devices:
            self.devices[name] = Device(name, self.window)
        return self.devices[name]

    # ---- MQTT side (network thread) -------------------------------------------
    def make_mqtt(self):
        m = self.cfg["mqtt"]
        cid = m["client_id"] or f"om2m-ipe-bridge-{uuid.uuid4().hex[:6]}"
        try:   # paho-mqtt >= 2.0
            c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=cid, clean_session=True)
        except AttributeError:   # paho-mqtt 1.x (Raspberry Pi OS Bookworm ships 1.6)
            c = mqtt.Client(client_id=cid, clean_session=True)
        if m["username"]:
            c.username_pw_set(m["username"], m["password"] or None)
        # the broker is local: retry fast, a sensor may already be waiting on it
        c.reconnect_delay_set(min_delay=1, max_delay=5)
        c.on_connect = self._on_connect
        c.on_disconnect = self._on_disconnect
        c.on_message = self._on_message
        return c

    def _on_connect(self, client, userdata, flags, rc, *args):
        code = getattr(rc, "value", rc)
        if code != 0:
            log.error("MQTT connect refused: %s", rc)
            return
        client.subscribe([(f"{self.prefix}/+/telemetry", 1), (f"{self.prefix}/+/status", 1)])
        self.mqtt_ok = True
        self._last_announce = ("", 0.0)       # re-announce membership on reconnect
        log.info("MQTT connected; subscribed to %s/+/telemetry and %s/+/status",
                 self.prefix, self.prefix)

    def _on_disconnect(self, client, userdata, *args):
        self.mqtt_ok = False
        log.warning("MQTT disconnected; paho will reconnect")

    def _on_message(self, client, userdata, msg):
        self.inbox.put((msg.topic, msg.payload, bool(msg.retain), time.time()))

    def _publish(self, topic, payload, retain=False, qos=1):
        if self.mqtt is not None and self.mqtt_ok:
            self.mqtt.publish(topic, payload, qos=qos, retain=retain)

    # ---- worker side ------------------------------------------------------------
    def handle(self, topic, payload, retained, rx_time):
        parts = topic.split("/")
        if len(parts) != 3 or parts[0] != self.prefix or parts[2] not in ("telemetry", "status"):
            return
        device, kind = parts[1], parts[2]
        self.stats["rx"] += 1
        if not DEVICE_ID_RE.match(device):
            self._reject(device, "bad_device_id")
            return
        if kind == "status" and not payload:
            self.stats["status_cleared"] += 1      # a sensor clearing its retained presence
            return
        try:
            msg = (validate_telemetry if kind == "telemetry" else validate_status)(device, payload)
        except Rejected as e:
            self._reject(device, str(e))
            return
        signer = None
        if self.id_mode == "require":
            try:
                signer = self.authenticate(device, kind, payload, msg, rx_time)
            except Rejected as e:
                self._reject(device, str(e))
                return
            self.stats["authenticated"] += 1

        dev = self.device(device)
        if kind == "telemetry":
            key, rn = reading_key(msg)
            if dev.seen(key):
                self.stats["duplicate"] += 1
                self._ack(device, msg)               # stop the sensor re-sending it
                return
            record = dict(msg)
            record["rx_ts"] = int(rx_time * 1000)
            record["ts_src"] = "device" if msg.get("ts", 0) > 0 else "bridge"
            if signer:
                record["signer"] = signer
            if self.node_label:
                record["node"] = self.node_label
            self._enqueue(("data", device, record, key, rn))
        else:
            sk = session_key(msg.get("session"))
            if sk and dev.last_session and sk < dev.last_session:
                self.stats["status_stale_ignored"] += 1
                log.info("%s: ignoring %s for old session %s (newest %s.%s)", device,
                         msg["state"], msg.get("session"), *dev.last_session)
                return
            if sk:
                dev.last_session = sk
            record = {"state": msg["state"], "id": device, "rx_ts": int(rx_time * 1000),
                      "retained": retained}
            for k in ("boot", "fw", "ip", "session", "epoch", "home", "broker", "pk", "sig"):
                if k in msg:
                    record[k] = msg[k]
            if signer:
                record["signer"] = signer
            if self.node_label:
                record["node"] = self.node_label
            self._enqueue(("status", device, record, None, None))

    def _ack(self, device, msg):
        a = {"id": device, "seq": msg["seq"], "node": self.node_label}
        if msg.get("v") == 2:
            a["epoch"] = msg["epoch"]
        else:
            a["boot"] = msg["boot"]
        if self.ack_key is not None:
            a["ts"] = int(time.time())
            payload = self._sign_ack(a, self.ack_key)
        else:
            payload = json.dumps(a, separators=(",", ":"))
        self._publish(f"{self.prefix}/{device}/ack", payload)
        self.stats["acks"] += 1

    def _reject(self, device, reason):
        self.stats["rejected"] += 1
        self.stats[f"rejected:{reason}"] += 1
        log.warning("rejected message from %s: %s", device, reason)

    def _enqueue(self, item):
        if len(self.pending) >= self.queue_max:
            self.pending.popleft()
            self.stats["dropped_overflow"] += 1
        self.pending.append(item)

    # ---- provisioning ------------------------------------------------------------
    def _acl(self, cse):
        """(acpi, daci) for new resources on this CSE. Looked up every time:
        acp ris are regenerated on every OM2M boot."""
        if self.protect:
            acp = cse.find_ri(self.dac_acp_name)
            dac = cse.find_ri(self.dac_name)
            if not acp or not dac:
                # provision-das.sh creates both at boot; until then, wait rather
                # than create an AE the chain does not protect.
                raise CseUnavailable(f"DAC wiring missing on {cse.base} "
                                     f"({self.dac_acp_name}={acp}, {self.dac_name}={dac})")
            return [acp], [dac]
        if not self.acp_name:
            return None, None
        ri = cse.find_ri(self.acp_name)
        if not ri:
            raise CseUnavailable(f"{self.acp_name} not found (OM2M still starting?)")
        return [ri], None

    def provision(self, dev, base):
        cse = self.cse(base)
        pl = dev.place(base)
        acpi, daci = self._acl(cse)
        lbl = dev.labels()
        ae = {"rn": dev.name, "api": self.api, "rr": False, "lbl": lbl}
        if acpi:
            ae["acpi"] = acpi
        if daci:
            ae["daci"] = daci
        # Originator C<device> pins the AE's ri to /<cse-id>/C<device>: stable
        # across OM2M restarts, so the on-chain policy/token key never changes.
        ae_ri, created = cse.create(cse.cse_root(), 2, "m2m:ae", ae,
                                    lookup_url=cse.hier(dev.name), origin=f"C{dev.name}")
        expect = f"/{cse.cse_id}/C{dev.name}"
        if ae_ri != expect:
            log.warning("%s: AE ri is %s, expected %s (on-chain resource key)", dev.name, ae_ri, expect)
        extra = {"acpi": acpi} if acpi else {}
        cnt = {}
        for name in (self.cnt_data, self.cnt_status):
            cnt[name], _ = cse.create(cse.url_for_ri(ae_ri), 3, "m2m:cnt",
                                      dict({"rn": name, "mni": self.mni}, **extra),
                                      lookup_url=cse.hier(dev.name, name))
        pl.ae_ri, pl.cnt_ri = ae_ri, cnt
        if pl.provisioned_once and dev.last_state and cse.latest_content(cnt[self.cnt_status]) is None:
            # OM2M lost its tree (restart / role switch): the sensor will not
            # re-announce, so re-write the state we last knew.
            cse.add_instance(cnt[self.cnt_status], {"state": dev.last_state, "id": dev.name,
                                                    "rx_ts": int(time.time() * 1000), "restored": True})
            self.stats["status_restored"] += 1
        pl.provisioned_once = True
        self.stats["provisioned"] += 1
        log.info("provisioned %s on %s (%s): AE %s acpi %s daci %s", dev.name, base,
                 "created" if created else "existing", ae_ri, acpi, daci)

    def _update_latest(self, cse, dev, pl, record):
        if not self.latest_label:
            return
        now = time.time()
        if now - dev.last_label_at < self.latest_min_s:
            return
        dev.last_label_at = now
        latest = {k: record[k] for k in ("epoch", "seq", "ts", "rx_ts", "temperature", "humidity",
                                          "light_raw", "light_pct", "node") if k in record}
        lbl = dev.labels() + ["latest=" + json.dumps(latest, separators=(",", ":"), sort_keys=True)]
        try:
            code = cse.update(pl.ae_ri, "m2m:ae", {"lbl": lbl})
            self.stats["latest_label" if code == 200 else "latest_label_failed"] += 1
        except (CseUnavailable, ResourceGone):
            self.stats["latest_label_failed"] += 1

    def _deliver(self, item):
        kind, device, record, key, rn = item
        base = self.resolver.target()
        if base is None:
            self.stats["no_target"] += 1
            raise CseUnavailable("no parent known yet (chain unreadable); buffering")
        cse = self.cse(base)
        dev = self.device(device)
        pl = dev.place(base)
        for attempt in (1, 2):
            if pl.ae_ri is None:
                self.provision(dev, base)
            try:
                if kind == "data":
                    try:
                        cse.add_instance(pl.cnt_ri[self.cnt_data], record, rn=rn)
                        self.stats["stored"] += 1
                        self._update_latest(cse, dev, pl, record)
                    except Duplicate:
                        self.stats["duplicate_cse"] += 1     # another bridge stored it first
                    dev.remember(key)
                    self._ack(device, record)
                    return
                return self._deliver_status(cse, dev, pl, record)
            except ResourceGone as e:
                if attempt == 2:
                    raise
                log.warning("%s; CSE probably restarted, re-provisioning %s on %s", e, device, base)
                self.stats["reprovision"] += 1
                pl.ae_ri, pl.cnt_ri = None, {}

    def _deliver_status(self, cse, dev, pl, record):
        cnt = pl.cnt_ri[self.cnt_status]
        prev = cse.latest_content(cnt)
        sk, pk = session_key(record.get("session")), session_key((prev or {}).get("session"))
        if sk and pk and sk < pk:
            # e.g. the Last Will of a broker this sensor left, fired after it
            # came online on another broker (whose bridge wrote the newer session)
            self.stats["status_stale_ignored"] += 1
            log.info("%s: stale %s for session %s ignored (stored session %s)", dev.name,
                     record["state"], record.get("session"), prev.get("session"))
            return
        if prev and prev.get("state") == record["state"] and (sk == pk or (record.get("retained") and not sk)):
            self.stats["status_unchanged"] += 1
            dev.last_state = record["state"]
            return
        cse.add_instance(cnt, record)
        dev.last_state = record["state"]
        self.stats["stored_status"] += 1
        log.info("%s is %s (session %s)", dev.name, record["state"], record.get("session", "-"))

    def flush(self):
        """Deliver pending items in order. Stops at the first transient failure."""
        while self.pending and not self.stop_evt.is_set():
            item = self.pending[0]
            try:
                self._deliver(item)
            except CseUnavailable as e:
                if self.cse_ok:
                    log.error("target CSE unavailable (%s); buffering, %d pending", e, len(self.pending))
                self.cse_ok = False
                self.stats["cse_errors"] += 1
                return False
            except (CseRejected, ResourceGone) as e:
                log.error("dropping record for %s: %s", item[1], e)
                self.stats["dropped_rejected_by_cse"] += 1
                d = self.devices.get(item[1])
                if d:
                    d.places.clear()
            self.pending.popleft()
            if not self.cse_ok:
                log.info("target CSE reachable again; replaying buffer")
                self.cse_ok = True
        return True

    # ---- membership announcements ------------------------------------------------
    def announce(self, force=False):
        members = self.cluster.snapshot()
        if not members:
            return
        compact = brokers_payload(members, ts=0)          # content without the timestamp
        last, at = self._last_announce
        now = time.time()
        if not force and compact == last and now - at < self.refresh_s:
            return
        self._publish(BROKERS_TOPIC, brokers_payload(members), retain=True)
        p = self.resolver.describe()
        doc = {"v": 1, "ts": int(now), "self": self.cluster.self_label,
               "members": [{"label": m.label, "host": m.host, "port": m.port, "cse": m.cse_url,
                            "addr": m.addr, "alive": m.alive} for m in members],
               "parent": {"label": p["label"], "addr": p["addr"], "epoch": p["epoch"],
                          "cse": p["base"]} if p else None,
               "target": self.resolver.mode, "ack_pk": self.ack_pk or None}
        self._publish(MEMBERS_TOPIC, json.dumps(doc, separators=(",", ":")), retain=True)
        if self.mqtt_ok:
            self._last_announce = (compact, now)
            self.stats["announcements"] += 1

    # ---- background loops ----------------------------------------------------------
    def _loop(self, period, fn):
        while not self.stop_evt.is_set():
            try:
                fn()
            except Exception as e:     # a background task must never die silently
                log.exception("background task failed: %s", e)
            self.stop_evt.wait(period)

    def _probe(self):
        self.cluster.reload()
        self.cluster.probe_once(self.mqtt_ok)

    # ---- main loop -----------------------------------------------------------------
    def run(self):
        client = self.make_mqtt()
        self.mqtt = client
        m = self.cfg["mqtt"]
        client.connect_async(m["host"], int(m["port"]), keepalive=30)
        client.loop_start()
        threads = [threading.Thread(target=self._loop, args=(self.resolver.poll_s, self.resolver.poll_once),
                                    daemon=True, name="parent")]
        if self.cluster.members or self.cluster.path:
            threads.append(threading.Thread(target=self._loop, args=(self.cluster.probe_s, self._probe),
                                            daemon=True, name="probe"))
        for t in threads:
            t.start()
        log.info("bridge started: MQTT %s:%s, target=%s (local CSE %s), node %s",
                 m["host"], m["port"], self.resolver.mode, self.resolver.local, self.node_label or "-")
        last_retry = last_stats = last_ann = last_save = time.time()
        try:
            while not self.stop_evt.is_set():
                try:
                    item = self.inbox.get(timeout=0.25)
                    self.handle(*item)
                    while True:
                        self.handle(*self.inbox.get_nowait())
                except queue.Empty:
                    pass
                now = time.time()
                if self.pending and (self.cse_ok or now - last_retry >= self.retry_s):
                    last_retry = now
                    self.flush()
                if now - last_ann >= min(self.announce_s, 5.0) or self._last_announce[0] == "":
                    last_ann = now
                    self.announce()
                if now - last_stats >= self.stats_s:
                    last_stats = now
                    self.log_stats()
                if self.id_mode == "require" and self.replay.dirty and now - last_save >= 1.0:
                    last_save = now
                    self._save_replay()
        finally:
            client.loop_stop()
            client.disconnect()
            deadline = time.time() + 5
            while self.pending and time.time() < deadline and self.flush() is not False:
                pass
            self.log_stats()
            self._save_replay()
            if self.pending:
                log.warning("exiting with %d undelivered records", len(self.pending))

    def _save_replay(self):
        if self.id_mode != "require":
            return
        try:
            self.replay.save()
        except OSError as e:
            log.error("cannot save the replay floor: %s", e)

    def log_stats(self):
        s = dict(self.stats)
        s["pending"] = len(self.pending)
        s["devices"] = len(self.devices)
        p = self.resolver.describe()
        s["parent"] = p["label"] if p else None
        s["parent_changes"] = self.resolver.changes
        log.info("stats %s", json.dumps(s, sort_keys=True))

    def check(self):
        """One-shot connectivity test against the current target CSE."""
        self.resolver.poll_once()
        base = self.resolver.target() or self.resolver.local
        cse = self.cse(base)
        r = cse._request("GET", cse.cse_root())
        print(f"target {base} ({self.resolver.mode}); GET {cse.cse_root()} -> {r.status_code}")
        if r.status_code != 200:
            print(r.text[:400])
            return 1
        dev = Device("ipe-bridge-probe", 16)
        self.provision(dev, base)
        pl = dev.place(base)
        print(f"probe AE {pl.ae_ri} containers {pl.cnt_ri}")
        cin = cse.add_instance(pl.cnt_ri[self.cnt_data], {"probe": True}, rn="e1-s0")
        print(f"probe contentInstance: {cin}")
        try:
            cse.add_instance(pl.cnt_ri[self.cnt_data], {"probe": True}, rn="e1-s0")
            print("WARNING: the CSE accepted a duplicate contentInstance name; "
                  "exactly-once then relies on the bridge cache alone")
        except Duplicate:
            print("duplicate contentInstance name rejected (409): exactly-once storage holds")
        code = cse.delete_ae(pl.ae_ri)
        if code not in (200, 202, 204):
            print(f"DELETE probe -> {code}: resource is locked (created without a usable ACP?)")
            return 3
        print(f"probe deleted (HTTP {code}): ACP attached correctly, nothing left behind")
        return 0


def main():
    ap = argparse.ArgumentParser(description="ESP32 MQTT -> OM2M (oneM2M) bridge, cluster edition")
    ap.add_argument("-c", "--config", help="path to bridge.conf")
    ap.add_argument("--check", action="store_true", help="test the target CSE and exit")
    ap.add_argument("--print-ack-key", action="store_true",
                    help="create (if needed) this bridge's ack key and print its PUBLIC key, then exit")
    args = ap.parse_args()

    cfg = load_config(args.config)
    if args.print_ack_key:
        cfg["ack"]["sign"] = "true"
        logging.basicConfig(level="WARNING")
        br = Bridge.__new__(Bridge)
        br.state_dir = cfg["bridge"]["state_dir"].strip()
        if br.state_dir:
            os.makedirs(br.state_dir, mode=0o700, exist_ok=True)
        br._init_ack(cfg)
        print(json.dumps({"node": cfg["cluster"]["self"] or cfg["om2m"]["node_label"], "apk": br.ack_pk}))
        return
    logging.basicConfig(level=cfg["bridge"]["log_level"].upper(),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if args.check:
        # one-shot probe, often run as another user (smoke_test.sh): it acks
        # nothing and must not touch the service's ack key or replay floor
        cfg["ack"]["sign"] = "false"
        cfg["bridge"]["state_dir"] = ""
    bridge = Bridge(cfg)
    if args.check:
        try:
            sys.exit(bridge.check())
        except (CseUnavailable, CseRejected, ResourceGone) as e:
            print(f"FAILED: {e}")
            sys.exit(2)

    def _stop(*_):
        bridge.stop_evt.set()
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    bridge.run()


if __name__ == "__main__":
    main()
