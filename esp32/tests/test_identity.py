#!/usr/bin/env python3
"""Per-device identity: signing format, Sui address derivation, registry checks,
and the bridge's accept/reject decisions (no broker, no CSE, no chain).

    python3 tests/test_identity.py
"""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "pi"))
import esp_identity as idm  # noqa: E402
import om2m_ipe_bridge as b  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402

DEV = "esp32-dht-01"
SEED = bytes(range(32))


def reading(**kw):
    d = {"v": 2, "id": DEV, "epoch": 3, "boot": "a1b2c3d4", "seq": 5, "ts": 0,
         "rssi": -60, "temperature": 24.5, "humidity": 55.0}
    d.update(kw)
    return d


class Vectors(unittest.TestCase):
    def test_rfc8032_test_1(self):
        # RFC 8032 section 7.1, TEST 1 (empty message): the library is plain Ed25519.
        sk = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
        self.assertEqual(idm.public_bytes(sk).hex(),
                         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        self.assertEqual(sk.sign(b"").hex(),
                         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
                         "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")

    def test_sui_address_matches_a_live_sui_key(self):
        # rpi1's node key, from `sui keytool list` (public key and address only).
        pk = bytes.fromhex("ffeaa754a11083a3246fd1a5233ddcb92938757887e5d859f35ec463e327e1c8")
        self.assertEqual(idm.sui_address(pk),
                         "0xef9c6271d8c6cc9e1d9707a117f876e7a8679509f141879bc05ae7bcffe1d5f9")


class Signing(unittest.TestCase):
    def setUp(self):
        self.sk = Ed25519PrivateKey.from_private_bytes(SEED)

    def test_roundtrip(self):
        raw = idm.sign_obj(reading(), self.sk).encode()
        msg = json.loads(raw)
        self.assertEqual(idm.verify_message(raw, msg), idm.public_bytes(self.sk))
        self.assertTrue(raw.endswith(b'"}') and b',"sig":"' in raw)

    def test_any_change_breaks_the_signature(self):
        raw = idm.sign_obj(reading(), self.sk)
        for a, c in (('"seq":5', '"seq":6'), ('"temperature":24.5', '"temperature":99.0'),
                     ('"id":"esp32-dht-01"', '"id":"esp32-dht-02"'), ('"epoch":3', '"epoch":4')):
            t = raw.replace(a, c).encode()
            with self.assertRaises(idm.IdentityError) as cm:
                idm.verify_message(t, json.loads(t))
            self.assertEqual(str(cm.exception), "bad_signature")

    def test_swapping_in_another_key_is_detected(self):
        raw = idm.sign_obj(reading(), self.sk)
        other = idm.public_bytes(Ed25519PrivateKey.generate()).hex()
        t = raw.replace(idm.public_bytes(self.sk).hex(), other).encode()
        with self.assertRaises(idm.IdentityError) as cm:
            idm.verify_message(t, json.loads(t))
        self.assertEqual(str(cm.exception), "bad_signature")

    def test_format_errors(self):
        unsigned = json.dumps(reading()).encode()
        for raw, why in ((unsigned, "unsigned"),
                         (idm.sign_obj(reading(), self.sk)[:-3].encode() + b'"}', "bad_sig_format"),
                         (idm.sign_obj(reading(), self.sk).replace('"}', '","x":1}').encode(), "bad_sig_format")):
            with self.assertRaises(idm.IdentityError) as cm:
                idm.verify_message(raw, json.loads(raw) if raw.endswith(b"}") else {})
            self.assertEqual(str(cm.exception), why)

    def test_parsed_message_must_equal_the_signed_body(self):
        raw = idm.sign_obj(reading(), self.sk).encode()
        msg = dict(json.loads(raw), temperature=99.0)    # what a caller would store
        with self.assertRaises(idm.IdentityError) as cm:
            idm.verify_message(raw, msg)
        self.assertEqual(str(cm.exception), "body_mismatch")

    def test_key_file_is_created_0600_and_reused(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "k", "dev.key")
            k1 = idm.load_or_create_key(p)
            k2 = idm.load_or_create_key(p)
            self.assertEqual(idm.public_bytes(k1), idm.public_bytes(k2))
            if os.name == "posix":
                self.assertEqual(os.stat(p).st_mode & 0o777, 0o600)


class FakeChain:
    """Stands in for GraphQL: addr -> registry entry; down -> raise."""

    def __init__(self):
        self.entries, self.down, self.calls = {}, False, 0

    def post(self, query, v):
        self.calls += 1
        if self.down:
            raise RuntimeError("503")
        if "asMoveObject" in query:
            return {"object": {"asMoveObject": {"contents": {"json": {"nodes": {"id": "0xtable"}}}}}}
        import base64
        addr = "0x" + base64.b64decode(v["bcs"]).hex()
        e = self.entries.get(addr)
        return {"address": {"dynamicField": {"value": {"__typename": "MoveValue", "json": e}} if e else None}}


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class Registry(unittest.TestCase):
    def setUp(self):
        self.pk = idm.public_bytes(Ed25519PrivateKey.from_private_bytes(SEED))
        self.addr = idm.sui_address(self.pk)
        self.chain, self.clock = FakeChain(), Clock()
        self.reg = idm.DeviceRegistry(self.chain.post, "0xreg", ttl_s=60, negative_ttl_s=15,
                                      max_stale_s=300, clock=self.clock)

    def register(self, role=3, cse_id=DEV):
        self.chain.entries[self.addr] = {"cse_id": cse_id, "role": role, "registered_at_ms": "1"}

    def reason(self, device=DEV):
        with self.assertRaises(idm.IdentityError) as cm:
            self.reg.check(device, self.pk)
        return str(cm.exception)

    def test_registered_device_passes_and_is_cached(self):
        self.register()
        self.assertEqual(self.reg.check(DEV, self.pk), self.addr)
        n = self.chain.calls
        self.reg.check(DEV, self.pk)
        self.assertEqual(self.chain.calls, n)

    def test_unregistered_wrong_role_wrong_name(self):
        self.assertEqual(self.reason(), "device_not_registered")
        self.clock.t += 16
        self.register(role=2)                    # a middleware node's key is not a device
        self.assertEqual(self.reason(), "device_wrong_role")
        self.clock.t += 61
        self.register()
        self.assertEqual(self.reason("esp32-dht-02"), "device_id_mismatch")

    def test_revocation_takes_effect_after_the_ttl(self):
        self.register()
        self.reg.check(DEV, self.pk)
        del self.chain.entries[self.addr]         # council id-deregister
        self.clock.t += 30
        self.assertEqual(self.reg.check(DEV, self.pk), self.addr)   # still cached
        self.clock.t += 31
        self.assertEqual(self.reason(), "device_not_registered")

    def test_chain_down(self):
        self.chain.down = True
        self.assertEqual(self.reason(), "identity_unavailable")       # nothing cached: closed
        self.chain.down = False
        self.register()
        self.clock.t += 16
        self.reg.check(DEV, self.pk)
        self.chain.down = True
        self.clock.t += 100                                         # past ttl, within max_stale
        self.assertEqual(self.reg.check(DEV, self.pk), self.addr)
        self.clock.t += 300
        self.assertEqual(self.reason(), "identity_unavailable")


class BridgeDecisions(unittest.TestCase):
    """Bridge.handle in identity.mode = require, with the registry faked."""

    def setUp(self):
        cfg = b.load_config(None)
        cfg["identity"]["mode"] = "require"
        cfg["identity"]["registry_id"] = "0xreg"
        cfg["identity"]["graphql_url"] = "http://127.0.0.1:9/graphql"
        self.br = b.Bridge(cfg)
        self.chain = FakeChain()
        self.br.registry = idm.DeviceRegistry(self.chain.post, "0xreg")
        self.sk = Ed25519PrivateKey.from_private_bytes(SEED)
        self.chain.entries[idm.sui_address(idm.public_bytes(self.sk))] = {
            "cse_id": DEV, "role": 3, "registered_at_ms": "1"}
        self.br._publish = lambda *a, **k: None

    def send(self, payload, kind="telemetry"):
        self.br.handle(f"sensors/{DEV}/{kind}", payload.encode() if isinstance(payload, str) else payload,
                       False, 1_800_000_000.0)

    def test_signed_registered_reading_is_queued_with_its_signer(self):
        self.send(idm.sign_obj(reading(), self.sk))
        self.assertEqual(len(self.br.pending), 1)
        rec = self.br.pending[0][2]
        self.assertEqual(rec["signer"], idm.sui_address(idm.public_bytes(self.sk)))
        self.assertIn("sig", rec)
        self.assertIn(f"signer/{rec['signer']}", self.br.devices[DEV].labels())

    def test_rejections_are_counted_and_never_queued(self):
        rogue = Ed25519PrivateKey.generate()
        self.send(json.dumps(reading()))                                   # unsigned
        self.send(idm.sign_obj(reading(), rogue))                          # not registered
        self.send(idm.sign_obj(reading(), self.sk).replace('"seq":5', '"seq":6'))  # tampered
        s = self.br.stats
        self.assertEqual(len(self.br.pending), 0)
        self.assertEqual(s["rejected:auth:unsigned"], 1)
        self.assertEqual(s["rejected:auth:device_not_registered"], 1)
        self.assertEqual(s["rejected:auth:bad_signature"], 1)

    def test_older_epoch_and_stale_timestamp_are_replays(self):
        self.send(idm.sign_obj(reading(epoch=4), self.sk))
        self.send(idm.sign_obj(reading(epoch=3, seq=9), self.sk))
        self.send(idm.sign_obj(reading(epoch=4, seq=6, ts=1_800_000_000 - 7200), self.sk))
        self.assertEqual(len(self.br.pending), 1)
        self.assertEqual(self.br.stats["rejected:auth:stale_epoch"], 1)
        self.assertEqual(self.br.stats["rejected:auth:stale_reading"], 1)

    def test_status_must_be_signed_too(self):
        self.send(json.dumps({"state": "offline", "id": DEV, "session": "3.1"}), "status")
        self.assertEqual(self.br.stats["rejected:auth:unsigned"], 1)
        self.send(idm.sign_obj({"state": "online", "id": DEV, "session": "3.2"}, self.sk), "status")
        self.assertEqual(len(self.br.pending), 1)
        self.assertEqual(self.br.pending[0][2]["signer"], idm.sui_address(idm.public_bytes(self.sk)))

    def test_mode_off_keeps_v2_behaviour(self):
        cfg = b.load_config(None)
        br = b.Bridge(cfg)
        br._publish = lambda *a, **k: None
        br.handle(f"sensors/{DEV}/telemetry", json.dumps(reading()).encode(), False, 1.0)
        self.assertEqual(len(br.pending), 1)
        self.assertNotIn("signer", br.pending[0][2])


if __name__ == "__main__":
    unittest.main(verbosity=2)
