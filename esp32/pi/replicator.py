"""
replicator.py - write every reading to EVERY CSE of the cluster, and acknowledge
it to the sensor only once a quorum of them hold it durably.

Why: with one copy on the parent, losing the parent (or restarting its
container) loses the readings stored there. With replication, a reading the
sensor has been told is safe (a signed ack) is on at least `quorum` CSEs, each
an on-disk H2 database (dbReset=false, WRITE_DELAY=0, host volume), so it
survives the loss of any (members - quorum) nodes. A reading that is NOT yet on
a quorum is not acknowledged, so it stays in the sensor's flash buffer and is
re-sent.

  store()        foreground, called by the bridge for each authenticated
                 reading: parallel POSTs to all members; 201 or 409 (already
                 there) both count as "held". Members that fail are recorded
                 in a per-member backlog. Members that keep failing are skipped
                 for a back-off period (circuit breaker) so a dead node cannot
                 slow every ack down to the HTTP timeout.
  backfill       background: drains each member's backlog when it is reachable.
  reconcile      background, leader only (the bridge on the parent, or the
                 first live member if the parent is down): compares the
                 reading names (e<epoch>-s<seq>) on every live CSE and copies
                 the gaps, so a node that was down while every bridge restarted
                 (backlogs are in memory), or lost its disk, still catches up.
                 On a member whose container is full (mni), readings older than
                 its oldest one were retention-evicted and are not re-added
                 (that would only churn the eviction); on any other member every
                 missing reading is a gap.

Content is copied byte-for-byte (the same "con" the first bridge wrote,
including the device signature), so all replicas hold identical records and
any of them can be verified against the device's on-chain key.

Protected reads on replicas: every CSE carries the same AE (ri /in-cse/C<dev>,
acpi acp_sui_dac, daci sui-dac), so a RETRIEVE on any replica is decided by the
Sui DAS of that node, exactly as on the parent.
"""
import collections
import concurrent.futures
import json
import logging
import re
import sys
import threading
import time

log = logging.getLogger("replicator")

RN_RE = re.compile(r"^e(\d+)-s(\d+)$")

DEFAULTS = {
    # mode = all: write to every member CSE and ack on quorum. off: v2 behaviour
    # (parent only, ack on the parent's 201).
    "mode": "off",
    # 0 = majority of the members file (5 nodes -> 3)
    "quorum": "0",
    "write_timeout_s": "3",
    "down_backoff_min_s": "5", "down_backoff_max_s": "60",
    "backlog_max": "50000",
    "backfill_interval_s": "5", "backfill_batch": "200",
    "reconcile_interval_s": "300", "reconcile_max_copies": "3000",
}


def rn_key(rn):
    m = RN_RE.match(rn or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


class Replicator:
    def __init__(self, bridge, cfg):
        r = cfg["replication"] if cfg.has_section("replication") else DEFAULTS
        g = lambda k: r.get(k, DEFAULTS[k])  # noqa: E731
        self.bridge = bridge
        # The bridge's OWN module: it runs as __main__, and "import om2m_ipe_bridge"
        # would load a second copy whose exception classes (Duplicate, ...) never
        # match what the bridge raises (a 409 would then count as a failure).
        self.mod = sys.modules[type(bridge).__module__]
        self.mode = g("mode").strip().lower()
        self.quorum_cfg = int(g("quorum"))
        self.write_timeout = float(g("write_timeout_s"))
        self.bo_min, self.bo_max = float(g("down_backoff_min_s")), float(g("down_backoff_max_s"))
        self.backlog_max = int(g("backlog_max"))
        self.backfill_s, self.backfill_batch = float(g("backfill_interval_s")), int(g("backfill_batch"))
        self.reconcile_s, self.reconcile_max = float(g("reconcile_interval_s")), int(g("reconcile_max_copies"))
        self.lock = threading.Lock()
        self.backlog = collections.defaultdict(collections.OrderedDict)   # label -> {(dev, rn): record}
        self.down_until, self.backoff = {}, {}
        self.bg_devices = {}                       # (label, device) -> private Device (background thread)
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=8, thread_name_prefix="repl")
        self.reconcile_now = threading.Event()
        self.was_alive = {}
        self.last_reconcile = 0.0

    @property
    def enabled(self):
        return self.mode == "all" and bool(self.bridge.cluster.snapshot())

    def quorum(self, n=None):
        n = len(self.bridge.cluster.snapshot()) if n is None else n
        return self.quorum_cfg if self.quorum_cfg > 0 else n // 2 + 1

    # ---- member state -----------------------------------------------------------
    def _parent_label(self):
        p = self.bridge.resolver.describe()
        return p["label"] if p else None

    def ordered_members(self):
        """Parent first (it is the CSE readers use), then the others in file order."""
        ms = self.bridge.cluster.snapshot()
        pl = self._parent_label()
        return sorted(ms, key=lambda m: 0 if m.label == pl else 1)

    def _is_down(self, label, now):
        return self.down_until.get(label, 0.0) > now

    def _mark(self, label, ok, now):
        with self.lock:
            if ok:
                if self.backoff.pop(label, None) is not None:
                    log.info("replica %s reachable again", label)
                self.down_until.pop(label, None)
            else:
                b = min(self.bo_max, self.backoff.get(label, self.bo_min / 2) * 2)
                self.backoff[label] = b
                self.down_until[label] = now + b

    def _queue_backlog(self, label, device, rn, record):
        with self.lock:
            q = self.backlog[label]
            q[(device, rn)] = record
            while len(q) > self.backlog_max:
                q.popitem(last=False)
                self.bridge.stats["repl_backlog_dropped"] += 1

    # ---- one write ----------------------------------------------------------------
    def _store_one(self, member, dev, record, rn):
        """-> 'stored' | 'duplicate'; raises on failure."""
        b = self.bridge
        m = self.mod
        CseUnavailable, Duplicate, ResourceGone = m.CseUnavailable, m.Duplicate, m.ResourceGone
        base = member.cse_url
        cse = b.cse(base)
        pl = dev.place(base)
        for attempt in (1, 2):
            if pl.ae_ri is None:
                b.provision(dev, base)
            try:
                cse.add_instance(pl.cnt_ri[b.cnt_data], record, rn=rn)
                return "stored"
            except Duplicate:
                return "duplicate"
            except ResourceGone:
                if attempt == 2:
                    raise
                pl.ae_ri, pl.cnt_ri = None, {}
        raise CseUnavailable("unreachable")

    # ---- foreground ---------------------------------------------------------------
    def store(self, dev, record, rn):
        """Write to every member in parallel. -> (held_labels, failed_labels)."""
        now = time.time()
        members = self.ordered_members()
        held, failed, futs = [], [], {}
        for m in members:
            if self._is_down(m.label, now):
                failed.append(m.label)
                self._queue_backlog(m.label, dev.name, rn, record)
                self.bridge.stats["repl_skipped_down"] += 1
                continue
            futs[self.pool.submit(self._store_one, m, dev, record, rn)] = m
        done = set()
        try:
            for f in concurrent.futures.as_completed(futs, timeout=self.write_timeout + 2):
                m = futs[f]
                done.add(f)
                try:
                    res = f.result()
                    held.append(m.label)
                    self.bridge.stats["repl_" + res] += 1
                    self._mark(m.label, True, time.time())
                except Exception as e:   # CseUnavailable, CseRejected, ...
                    self._fail(m, dev.name, rn, record, failed, e)
        except concurrent.futures.TimeoutError:
            for f, m in futs.items():
                if f not in done:     # still running: a hanging node must not hold up the ack
                    self._fail(m, dev.name, rn, record, failed, "timeout")
        return held, failed

    def _fail(self, m, device, rn, record, failed, err):
        failed.append(m.label)
        self.bridge.stats["repl_failed"] += 1
        self._mark(m.label, False, time.time())
        self._queue_backlog(m.label, device, rn, record)
        log.debug("replica %s: %s %s failed: %s", m.label, device, rn, err)

    def exists_anywhere(self, device, rn):
        """True if any live member already holds this reading (used to ack a
        re-sent reading the replay floor rejects as stale)."""
        b = self.bridge
        now = time.time()
        for m in self.ordered_members():
            if self._is_down(m.label, now):
                continue
            cse = b.cse(m.cse_url)
            try:
                r = cse._request("GET", cse.hier(device, b.cnt_data, rn))
            except Exception:
                continue
            if r.status_code == 200:
                return True
        return False

    def floor_candidates(self):
        """Live members, parent first: the replay floor takes the max over them."""
        now = time.time()
        return [m for m in self.ordered_members() if not self._is_down(m.label, now)]

    # ---- background ---------------------------------------------------------------
    def _bg_dev(self, label, device):
        Device = self.mod.Device
        k = (label, device)
        if k not in self.bg_devices:
            self.bg_devices[k] = Device(device, 16)
        return self.bg_devices[k]

    def backfill_once(self):
        now = time.time()
        for m in self.bridge.cluster.snapshot():
            if self._is_down(m.label, now):
                continue
            with self.lock:
                q = self.backlog.get(m.label)
                items = list(q.items())[: self.backfill_batch] if q else []
            for (device, rn), record in items:
                try:
                    self._store_one(m, self._bg_dev(m.label, device), record, rn)
                except Exception as e:
                    self._mark(m.label, False, time.time())
                    log.info("backfill to %s paused: %s", m.label, e)
                    break
                with self.lock:
                    self.backlog[m.label].pop((device, rn), None)
                self.bridge.stats["repl_backfilled"] += 1
                self._mark(m.label, True, time.time())

    def is_leader(self):
        ms = self.bridge.cluster.snapshot()
        me = self.bridge.cluster.self_label
        pl = self._parent_label()
        alive = {m.label: m.alive for m in ms}
        if pl and alive.get(pl):
            return pl == me
        first = next((m.label for m in ms if m.alive), None)
        return first == me

    def _names(self, cse, *path, ty):
        r = cse._request("GET", cse.hier(*path) + f"?fu=1&ty={ty}")
        if r.status_code != 200:
            return None
        try:
            return [u.rsplit("/", 1)[-1] for u in r.json().get("m2m:uril", [])]
        except ValueError:
            return None

    def reconcile_once(self):
        b = self.bridge
        now = time.time()
        live = [m for m in b.cluster.snapshot() if m.alive and not self._is_down(m.label, now)]
        if len(live) < 2:
            return 0
        devices = set()
        for m in live:
            cse = b.cse(m.cse_url)
            try:
                r = cse._request("GET", cse.cse_root() + "?fu=1&ty=2&lbl=type/esp32")
                if r.status_code == 200:
                    devices.update(u.rsplit("/", 1)[-1] for u in r.json().get("m2m:uril", []))
            except Exception:
                pass
        copies = 0
        for device in sorted(devices):
            have = {}
            for m in live:
                try:
                    names = self._names(b.cse(m.cse_url), device, b.cnt_data, ty=4)
                except Exception:
                    names = None
                if names is not None:
                    have[m.label] = {n for n in names if rn_key(n)}
            if len(have) < 2:
                continue
            union = set().union(*have.values())
            for m in live:
                mine = have.get(m.label)
                if mine is None:
                    # AE/container missing on this member: everything is a gap
                    mine = set()
                # Below a member's oldest reading is evicted history ONLY if its
                # container is full (mni); a member with room was wiped or down,
                # so everything it lacks is a gap. Never more than mni copies.
                floor = min((rn_key(n) for n in mine), default=None) if len(mine) >= b.mni else None
                missing = sorted((n for n in union - mine if floor is None or rn_key(n) > floor),
                                 key=rn_key)[-b.mni:]
                for rn in missing:
                    if copies >= self.reconcile_max:
                        return copies
                    src = next((o for o in live if o.label != m.label and rn in have.get(o.label, ())), None)
                    if src is None:
                        continue
                    scse = b.cse(src.cse_url)
                    try:
                        r = scse._request("GET", scse.hier(device, b.cnt_data, rn))
                        if r.status_code != 200:
                            continue
                        con = scse._resource(r).get("con")
                        record = json.loads(con)
                        self._store_one(m, self._bg_dev(m.label, device), record, rn)
                    except Exception as e:
                        log.info("reconcile %s -> %s paused: %s", device, m.label, e)
                        break
                    copies += 1
                    b.stats["repl_reconciled"] += 1
        if copies:
            log.info("reconcile: copied %d reading(s) between replicas", copies)
        return copies

    def background(self, stop_evt):
        while not stop_evt.is_set():
            try:
                now = time.time()
                for m in self.bridge.cluster.snapshot():
                    if m.alive and not self.was_alive.get(m.label, True):
                        log.info("member %s came back: reconcile scheduled", m.label)
                        self.reconcile_now.set()
                    self.was_alive[m.label] = m.alive
                self.backfill_once()
                due = now - self.last_reconcile >= self.reconcile_s or self.reconcile_now.is_set()
                if due and self.is_leader():
                    self.reconcile_now.clear()
                    self.last_reconcile = now
                    self.reconcile_once()
            except Exception as e:     # a background task must never die silently
                log.exception("replication background task failed: %s", e)
            stop_evt.wait(self.backfill_s)

    def backlog_sizes(self):
        with self.lock:
            return {k: len(v) for k, v in self.backlog.items() if v}
