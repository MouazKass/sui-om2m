#!/usr/bin/env python3
"""Unit tests for the bridge's pure logic (no broker, no CSE).

    python3 tests/test_bridge_unit.py
"""
import base64
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "pi"))
sys.path.insert(0, os.path.join(HERE, "..", "sim"))
import om2m_ipe_bridge as b  # noqa: E402
from esp32_sim import Selector  # noqa: E402

V2 = {"v": 2, "id": "esp32-dht-01", "epoch": 7, "boot": "a1b2c3d4", "seq": 12, "ts": 0,
      "rssi": -60, "temperature": 24.5, "humidity": 55.0}


def raw(d):
    return json.dumps(d).encode()


class Validation(unittest.TestCase):
    def test_v2_accepted_and_keyed_by_epoch_seq(self):
        m = b.validate_telemetry("esp32-dht-01", raw(V2))
        key, rn = b.reading_key(m)
        self.assertEqual(key, ("e", 7, 12))
        self.assertEqual(rn, "e7-s12")

    def test_v1_still_accepted(self):
        d = dict(V2, v=1)
        d.pop("epoch")
        key, rn = b.reading_key(b.validate_telemetry("esp32-dht-01", raw(d)))
        self.assertEqual(rn, "ba1b2c3d4-s12")

    def test_rejections(self):
        for bad, why in ((dict(V2, epoch=0), "bad_epoch"), (dict(V2, v=3), "bad_version"),
                         (dict(V2, id="other"), "id_topic_mismatch"), (dict(V2, humidity=150.0), "range_humidity"),
                         (dict(V2, seq=-1), "bad_seq"), (dict(V2, seq=True), "bad_seq")):
            with self.assertRaises(b.Rejected) as cm:
                b.validate_telemetry("esp32-dht-01", raw(bad))
            self.assertEqual(str(cm.exception), why)
        with self.assertRaises(b.Rejected):
            b.validate_telemetry("esp32-dht-01", b"{oops")

    def test_same_reading_same_key_across_brokers(self):
        a = b.reading_key(b.validate_telemetry("esp32-dht-01", raw(dict(V2, via="rpi2"))))
        c = b.reading_key(b.validate_telemetry("esp32-dht-01", raw(dict(V2, via="rpi3"))))
        self.assertEqual(a, c)


class Sessions(unittest.TestCase):
    def test_ordering(self):
        self.assertLess(b.session_key("3.2"), b.session_key("3.10"))
        self.assertLess(b.session_key("3.99"), b.session_key("4.1"))
        self.assertIsNone(b.session_key("x"))

    def test_status_session_validated(self):
        ok = {"state": "offline", "id": "d1", "session": "4.2"}
        self.assertEqual(b.validate_status("d1", raw(ok))["session"], "4.2")
        with self.assertRaises(b.Rejected):
            b.validate_status("d1", raw(dict(ok, session="4-2")))


class Membership(unittest.TestCase):
    TEXT = """# label host port cse addr
rpi1 10.25.96.200 1883 http://10.25.96.200:8282 0xEF9C
rpi2 10.25.96.201 1883 http://10.25.96.201:8282/
"""

    def test_parse_and_payload_is_what_the_firmware_learns(self):
        ms = b.parse_members(self.TEXT)
        self.assertEqual([m.label for m in ms], ["rpi1", "rpi2"])
        self.assertEqual(ms[0].addr, "0xef9c")
        self.assertEqual(ms[1].cse_url, "http://10.25.96.201:8282")
        ms[0].alive = True
        p = b.brokers_payload(ms, ts=123)
        self.assertEqual(p, "v1;123;rpi1=10.25.96.200:1883:1,rpi2=10.25.96.201:1883:0")
        s = Selector()
        self.assertEqual(s.learn(p, "10.25.96."), 2)
        self.assertFalse(s.b[s.find("rpi2")].alive)

    def test_bad_line_rejected(self):
        with self.assertRaises(ValueError):
            b.parse_members("RPI1 10.25.96.200 1883 http://x")

    def test_file_reload_on_change(self):
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write(self.TEXT)
        cfg = b.load_config(None)
        cfg["cluster"]["members_file"] = f.name
        c = b.Cluster(cfg)
        self.assertEqual(len(c.members), 2)
        with open(f.name, "a") as g:
            g.write("rpi5 10.25.96.205 1883 http://10.25.96.205:8282\n")
        os.utime(f.name, (os.path.getatime(f.name), os.path.getmtime(f.name) + 5))
        self.assertTrue(c.reload())
        self.assertEqual([m.label for m in c.members], ["rpi1", "rpi2", "rpi5"])
        os.unlink(f.name)


class Resolver(unittest.TestCase):
    PARENT = "0x" + "ab" * 32
    OTHER = "0x" + "cd" * 32

    def make(self, answers):
        cfg = b.load_config(None)
        cfg["cluster"].update(target="parent", graphql_url="http://gql", cluster_id="0xc1",
                              package_original_id="0xp")
        r = b.ParentResolver(cfg, None)

        def fake_q(query, variables):
            if "dynamicField" in query:
                v = answers.get(variables["type"].rsplit("::", 1)[1])
                return {"object": {"dynamicField": None if v is None else
                                   {"value": {"__typename": "MoveValue", "json": v}}}}
            return {"object": {"asMoveObject": {"contents": {"json": {
                "current_parent": self.PARENT, "epoch": "5"}}}}}
        r._q = fake_q
        return r

    def test_poa_used(self):
        poa = base64.b64encode(b"http://10.25.96.200:8282/").decode()
        r = self.make({"ParentPoaKey": poa})
        r.poll_once()
        self.assertEqual(r.target(), "http://10.25.96.200:8282")
        self.assertEqual(r.describe()["epoch"], 5)

    def test_poa_from_a_deposed_parent_is_ignored(self):
        poa = base64.b64encode(b"http://10.25.96.200:8282/").decode()
        r = self.make({"ParentPoaKey": poa, "ParentPoaOwnerKey": self.OTHER})
        r.poll_once()
        self.assertIsNone(r.target())          # no members table to fall back on: buffer

    def test_sticky_on_error(self):
        poa = base64.b64encode(b"http://10.25.96.203:8282").decode()
        r = self.make({"ParentPoaKey": poa})
        r.poll_once()

        def boom(*a):
            raise RuntimeError("503")
        r._q = boom
        r.poll_once()
        self.assertEqual(r.target(), "http://10.25.96.203:8282")
        self.assertIn("503", r.last_error)


if __name__ == "__main__":
    unittest.main(verbosity=1)
