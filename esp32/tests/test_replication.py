"""Replication + quorum ack (esp32/pi/replicator.py).

Five fake CSEs stand in for the five nodes' OM2M. A reading must be acked only
once a quorum (3 of 5) holds it; members that miss it are backfilled; the
leader's reconcile copies gaps but never re-adds readings older than a
member's own span; a re-sent reading the replay floor calls stale is acked if
it is already stored.
"""
import json
import os
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "pi"))
sys.path.insert(0, HERE)

import esp_identity as idm  # noqa: E402
import om2m_ipe_bridge as b  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402
from test_identity import FakeChain, reading, DEV, SEED  # noqa: E402

LABELS = ["rpi1", "rpi2", "rpi3", "rpi4", "rpi5"]


class Resp:
    def __init__(self, code, body=None):
        self.status_code, self._b = code, body

    def json(self):
        if self._b is None:
            raise ValueError("no body")
        return self._b


class FakeCse:
    """Just enough of OneM2MClient for provision(), add_instance() and the
    discovery / existence GETs the replicator issues."""

    def __init__(self, base):
        self.base, self.cse_id = base, "in-cse"
        self.down = False
        self.data = {}                     # device -> {rn: con-dict}
        self.status = []
        self.calls = 0

    def _chk(self):
        self.calls += 1
        if self.down:
            raise b.CseUnavailable(f"{self.base} down")

    def cse_root(self):
        return f"{self.base}/~/in-cse"

    def hier(self, *names):
        return "/".join([f"{self.base}/~/in-cse/in-name", *names])

    def url_for_ri(self, ri):
        return f"{self.base}/~{ri}"

    def find_ri(self, *names):
        self._chk()
        return "/in-cse/" + "-".join(names)

    def create(self, parent_url, ty, key, attrs, lookup_url, origin=None):
        self._chk()
        if ty == 2:
            self.data.setdefault(attrs["rn"], {})
            return f"/in-cse/C{attrs['rn']}", True
        return f"{parent_url}|{attrs['rn']}", True

    def latest_content(self, ri):
        self._chk()
        return None

    def latest_at(self, url):
        self._chk()
        dev = url.split("/in-name/")[1].split("/")[0]
        rns = sorted(self.data.get(dev, {}), key=lambda r: tuple(int(x[1:]) for x in r.split("-")))
        return self.data[dev][rns[-1]] if rns else None

    def add_instance(self, cnt_ri, content, rn=None):
        self._chk()
        if cnt_ri.endswith("|status"):
            self.status.append(dict(content))
            return "/in-cse/cin-s"
        dev = cnt_ri.split("|")[0].split("/in-cse/C")[1]
        store = self.data.setdefault(dev, {})
        if rn in store:
            raise b.Duplicate(rn)
        store[rn] = dict(content)
        return "/in-cse/cin-x"

    def update(self, ri, key, attrs):
        self._chk()
        return 200

    @staticmethod
    def _resource(resp):
        return resp.json()

    def _request(self, method, url):
        self._chk()
        path = url.split("/in-name", 1)[1] if "/in-name" in url else ""
        if "?fu=1&ty=2" in url:
            return Resp(200, {"m2m:uril": [f"/in-cse/in-name/{d}" for d in self.data]})
        if "?fu=1&ty=4" in url:
            dev = path.strip("/").split("/")[0]
            if dev not in self.data:
                return Resp(404)
            return Resp(200, {"m2m:uril": [f"/in-cse/in-name/{dev}/data/{rn}" for rn in self.data[dev]]})
        parts = path.strip("/").split("/")
        if len(parts) == 3:
            dev, _, rn = parts
            if rn in self.data.get(dev, {}):
                return Resp(200, {"con": json.dumps(self.data[dev][rn])})
        return Resp(404)


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        mf = os.path.join(self.dir.name, "members.conf")
        with open(mf, "w") as f:
            for i, lbl in enumerate(LABELS):
                f.write(f"{lbl} 10.0.0.{i + 1} 1883 http://10.0.0.{i + 1}:8282\n")
        self.mf = mf
        self.cses = {f"http://10.0.0.{i + 1}:8282": FakeCse(f"http://10.0.0.{i + 1}:8282")
                     for i in range(5)}

    def tearDown(self):
        self.dir.cleanup()

    def bridge(self, identity=False, me="rpi1"):
        cfg = b.load_config(None)
        cfg["cluster"]["members_file"] = self.mf
        cfg["cluster"]["self"] = me
        cfg["replication"]["mode"] = "all"
        cfg["replication"]["write_timeout_s"] = "2"
        if identity:
            cfg["identity"]["mode"] = "require"
            cfg["identity"]["registry_id"] = "0xreg"
            cfg["identity"]["graphql_url"] = "http://127.0.0.1:9/graphql"
            cfg["bridge"]["state_dir"] = self.dir.name
        br = b.Bridge(cfg)
        for m in br.cluster.snapshot():
            m.alive = True
        br.cse = lambda base: self.cses[base]
        br.resolver.target = lambda: "http://10.0.0.2:8282"
        br.resolver.describe = lambda: {"label": "rpi2", "addr": "", "epoch": 8, "base": "http://10.0.0.2:8282"}
        self.acks = []
        br._publish = lambda t, p, **k: self.acks.append(json.loads(p)) if t.endswith("/ack") else None
        return br

    def send(self, br, **kw):
        br.handle(f"sensors/{DEV}/telemetry", json.dumps(reading(**kw)).encode(), False, time.time())
        br.flush()

    def held(self, rn):
        return sum(1 for c in self.cses.values() if rn in c.data.get(DEV, {}))

    def down(self, *idx):
        for i in idx:
            self.cses[f"http://10.0.0.{i}:8282"].down = True

    def up(self, *idx):
        for i in idx:
            self.cses[f"http://10.0.0.{i}:8282"].down = False


class Quorum(Base):
    def test_default_quorum_is_a_majority(self):
        self.assertEqual(self.bridge().replicator.quorum(), 3)

    def test_all_up_stores_everywhere_and_acks(self):
        br = self.bridge()
        self.send(br, epoch=3, seq=1)
        self.assertEqual(self.held("e3-s1"), 5)
        self.assertEqual([a["seq"] for a in self.acks], [1])

    def test_parent_and_one_more_down_still_acks_on_three(self):
        br = self.bridge()
        self.down(2, 4)                                   # rpi2 is the parent
        self.send(br, epoch=3, seq=1)
        self.assertEqual(self.held("e3-s1"), 3)
        self.assertEqual(len(self.acks), 1)
        self.assertEqual(br.replicator.backlog_sizes(), {"rpi2": 1, "rpi4": 1})

    def test_no_quorum_no_ack_and_the_reading_stays_pending(self):
        br = self.bridge()
        self.down(2, 3, 4)
        self.send(br, epoch=3, seq=1)
        self.assertEqual(self.acks, [])
        self.assertEqual(len(br.pending), 1)
        self.assertEqual(br.stats["repl_no_quorum"], 1)
        # two come back; the retry reaches quorum (the 2 already holding it answer 409)
        self.up(3, 4)
        br.replicator.down_until.clear()
        br.flush()
        self.assertEqual(len(self.acks), 1)
        self.assertEqual(len(br.pending), 0)
        self.assertEqual(self.held("e3-s1"), 4)
        self.assertGreaterEqual(br.stats["repl_duplicate"], 2)

    def test_a_dead_member_is_skipped_during_its_backoff(self):
        br = self.bridge()
        self.down(5)
        self.send(br, epoch=3, seq=1)
        calls = self.cses["http://10.0.0.5:8282"].calls
        self.send(br, epoch=3, seq=2)
        self.assertEqual(self.cses["http://10.0.0.5:8282"].calls, calls)   # not even tried
        self.assertEqual(br.stats["repl_skipped_down"], 1)
        self.assertEqual(len(self.acks), 2)


class StatusNeverBlocks(Base):
    def test_status_with_the_parent_cse_down_does_not_hold_up_readings(self):
        br = self.bridge()
        self.down(2)                                      # the parent's CSE (rpi2) is stopped
        status = {"state": "online", "id": DEV, "session": "9.1"}
        br.handle(f"sensors/{DEV}/status", json.dumps(status).encode(), False, time.time())
        self.send(br, epoch=3, seq=1)                     # queued BEHIND the status item
        self.assertEqual([a["seq"] for a in self.acks], [1])
        self.assertEqual(len(br.pending), 0)
        self.assertEqual(br.stats["status_replicated"], 1)


class Backfill(Base):
    def test_backlog_is_drained_when_the_member_returns(self):
        br = self.bridge()
        self.down(4)
        for s in range(1, 6):
            self.send(br, epoch=3, seq=s)
        self.assertEqual(br.replicator.backlog_sizes(), {"rpi4": 5})
        self.up(4)
        br.replicator.down_until.clear()
        br.replicator.backfill_once()
        self.assertEqual(br.replicator.backlog_sizes(), {})
        self.assertEqual(len(self.cses["http://10.0.0.4:8282"].data[DEV]), 5)
        # the copies are the same records
        self.assertEqual(self.cses["http://10.0.0.4:8282"].data[DEV]["e3-s2"],
                         self.cses["http://10.0.0.1:8282"].data[DEV]["e3-s2"])


class Reconcile(Base):
    def test_leader_is_the_parent_bridge_or_the_first_live_member(self):
        self.assertTrue(self.bridge(me="rpi2").replicator.is_leader())
        br = self.bridge(me="rpi1")
        self.assertFalse(br.replicator.is_leader())
        next(m for m in br.cluster.snapshot() if m.label == "rpi2").alive = False
        self.assertTrue(br.replicator.is_leader())

    def test_gaps_are_copied_but_evicted_history_is_not(self):
        br = self.bridge(me="rpi2")
        br.mni = 6                                       # rpi5 below is full: older = evicted
        for s in range(10, 20):
            self.send(br, epoch=3, seq=s)
        lag = self.cses["http://10.0.0.5:8282"].data[DEV]
        for s in (10, 11, 15, 16):                       # 10,11: older than its new floor (evicted)
            del lag[f"e3-s{s}"]                           # 15,16: a gap inside its span
        n = br.replicator.reconcile_once()
        self.assertEqual(n, 2)
        self.assertIn("e3-s15", lag)
        self.assertIn("e3-s16", lag)
        self.assertNotIn("e3-s10", lag)

    def test_a_wiped_replica_with_room_gets_its_older_readings_back(self):
        br = self.bridge(me="rpi2")
        for s in range(10, 20):
            self.send(br, epoch=3, seq=s)
        lag = self.cses["http://10.0.0.5:8282"].data[DEV]
        for s in range(10, 15):                          # lost its first half (disk loss / wipe)
            del lag[f"e3-s{s}"]
        br.replicator.reconcile_once()
        self.assertEqual(len(lag), 10)

    def test_an_empty_replica_gets_the_newest_mni_readings(self):
        br = self.bridge(me="rpi2")
        for s in range(5):
            self.send(br, epoch=3, seq=s)
        self.cses["http://10.0.0.3:8282"].data.clear()   # wiped node (no AE at all)
        br.replicator.reconcile_once()
        self.assertEqual(len(self.cses["http://10.0.0.3:8282"].data[DEV]), 5)


class RunAsMain(Base):
    def test_409_is_held_when_the_bridge_runs_as_main(self):
        """The bridge runs as __main__: replicator must use THAT module's
        exception classes, or a 409 on a re-sent reading counts as a failure
        and a backlog never reaches quorum (seen in run_replication_e2e R2)."""
        import importlib.util
        spec = importlib.util.spec_from_file_location("bridge_as_main", b.__file__)
        mainmod = importlib.util.module_from_spec(spec)
        sys.modules["bridge_as_main"] = mainmod
        spec.loader.exec_module(mainmod)
        self.assertIsNot(mainmod.Duplicate, b.Duplicate)
        cfg = mainmod.load_config(None)
        cfg["cluster"]["members_file"] = self.mf
        cfg["cluster"]["self"] = "rpi1"
        cfg["replication"]["mode"] = "all"
        br = mainmod.Bridge(cfg)
        for m in br.cluster.snapshot():
            m.alive = True

        class Dup409:
            def __init__(self, base):
                self.base, self.cse_id = base, "in-cse"
            def find_ri(self, *n): return "/in-cse/x"
            def cse_root(self): return self.base
            def hier(self, *n): return "/".join([self.base, *n])
            def url_for_ri(self, ri): return self.base + ri
            def create(self, parent, ty, key, attrs, lookup_url, origin=None):
                return (f"/in-cse/C{attrs['rn']}" if ty == 2 else f"{parent}|{attrs['rn']}"), False
            def latest_content(self, ri): return None
            def add_instance(self, ri, content, rn=None): raise mainmod.Duplicate(rn)
            def update(self, *a): return 200
        br.cse = lambda base: Dup409(base)
        br.resolver.describe = lambda: None
        held, failed = br.replicator.store(br.device(DEV), {"seq": 1}, "e1-s1")
        self.assertEqual((len(held), failed), (5, []))
        self.assertEqual(br.stats["repl_duplicate"], 5)


class StaleButStored(Base):
    def test_a_resent_reading_that_is_already_stored_is_acked_not_wedged(self):
        sk = Ed25519PrivateKey.from_private_bytes(SEED)
        chain = FakeChain()
        chain.entries[idm.sui_address(idm.public_bytes(sk))] = {"cse_id": DEV, "role": 3, "registered_at_ms": "1"}
        br = self.bridge(identity=True)
        br.registry = idm.DeviceRegistry(chain.post, "0xreg")
        now = time.time()
        msg = lambda e, s: idm.sign_obj(reading(epoch=e, seq=s, ts=int(now)), sk).encode()  # noqa: E731
        br.handle(f"sensors/{DEV}/telemetry", msg(3, 1), False, now)
        br.flush()
        br.handle(f"sensors/{DEV}/telemetry", msg(4, 0), False, now)
        br.flush()
        self.assertEqual(len(self.acks), 2)
        br.devices[DEV].recent.clear()                    # e.g. a different bridge, no cache
        br.handle(f"sensors/{DEV}/telemetry", msg(3, 1), False, now)   # stale epoch, but stored
        self.assertEqual(br.stats["acked_stale_stored"], 1)
        self.assertEqual(len(self.acks), 3)
        br.handle(f"sensors/{DEV}/telemetry", msg(3, 2), False, now)   # stale and never stored
        self.assertEqual(br.stats["rejected:auth:stale_epoch"], 1)      # still rejected, not stored
        self.assertEqual(self.held("e3-s2"), 0)
        self.assertEqual(len(self.acks), 4)                               # but the board may drop it
        self.assertTrue(self.acks[-1].get("stale"))
        self.assertNotIn("stale", self.acks[2])                           # a normal ack is unmarked


if __name__ == "__main__":
    unittest.main(verbosity=2)
