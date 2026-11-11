#!/usr/bin/env python3
"""Signed acknowledgements and the durable replay floor (bridge v2.2).

No broker, no CSE, no chain: the registry and the target CSE are faked.

    python3 tests/test_ack_replay.py
"""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "pi"))
sys.path.insert(0, HERE)
import esp_identity as idm  # noqa: E402
import om2m_ipe_bridge as b  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402
from test_identity import FakeChain, reading, DEV, SEED  # noqa: E402

T = 1_800_000_000.0


class AckFormat(unittest.TestCase):
    def setUp(self):
        self.bridge = Ed25519PrivateKey.generate()
        self.trusted = {idm.public_bytes(self.bridge).hex(): "rpi2"}
        self.base = {"id": DEV, "seq": 7, "node": "rpi2", "epoch": 3, "ts": 0}

    def reason(self, raw, epoch=3, device=DEV):
        with self.assertRaises(idm.IdentityError) as cm:
            idm.verify_ack(raw.encode() if isinstance(raw, str) else raw, device, epoch, self.trusted)
        return str(cm.exception)

    def test_genuine_ack_verifies_and_sig_is_last(self):
        raw = idm.sign_ack(self.base, self.bridge)
        self.assertTrue(raw.endswith('"}') and ',"sig":"' in raw)
        d = idm.verify_ack(raw.encode(), DEV, 3, self.trusted)
        self.assertEqual((d["seq"], d["epoch"], d["id"]), (7, 3, DEV))

    def test_forgeries_are_rejected(self):
        rogue = Ed25519PrivateKey.generate()
        self.assertEqual(self.reason(json.dumps(self.base)), "ack_unsigned")
        self.assertEqual(self.reason(idm.sign_ack(self.base, rogue)), "ack_untrusted_key")
        good = idm.sign_ack(self.base, self.bridge)
        self.assertEqual(self.reason(good.replace('"seq":7', '"seq":8')), "bad_signature")
        # a trusted apk pasted onto a rogue signature
        forged = idm.sign_ack(self.base, rogue).replace(idm.public_bytes(rogue).hex(),
                                                        idm.public_bytes(self.bridge).hex())
        self.assertEqual(self.reason(forged), "bad_signature")

    def test_ack_is_bound_to_device_and_epoch(self):
        self.assertEqual(self.reason(idm.sign_ack(dict(self.base, id="esp32-other"), self.bridge)),
                         "ack_wrong_device")
        self.assertEqual(self.reason(idm.sign_ack(self.base, self.bridge), epoch=4), "ack_wrong_epoch")

    def test_domain_separation_device_signature_is_not_an_ack(self):
        # the same key signing a DEVICE message (sig domain) must never pass as an ack
        obj = dict(self.base)
        obj["apk"] = idm.public_bytes(self.bridge).hex()
        dev_signed = idm.sign_body(json.dumps(obj, separators=(",", ":")), self.bridge, idm.DOMAIN)
        self.assertEqual(self.reason(dev_signed), "bad_signature")

    def test_trusted_key_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "keys.txt")
            pk = idm.public_bytes(self.bridge).hex()
            with open(p, "w") as f:
                f.write(f"# pinned\nrpi2 {pk}\n\n")
            self.assertEqual(idm.load_trusted_ack_keys(p), {pk: "rpi2"})
            with open(p, "w") as f:
                f.write("rpi2 abcd\n")
            with self.assertRaises(ValueError):
                idm.load_trusted_ack_keys(p)


class BridgeAcks(unittest.TestCase):
    def test_bridge_signs_its_acks_with_a_key_made_in_its_state_dir(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = b.load_config(None)
            cfg["ack"]["sign"] = "true"
            cfg["bridge"]["state_dir"] = d
            br = b.Bridge(cfg)
            sent = []
            br._publish = lambda t, p, **k: sent.append((t, p))
            br._ack(DEV, {"v": 2, "epoch": 3, "seq": 9})
            self.assertEqual(os.stat(os.path.join(d, "ack.key")).st_mode & 0o777, 0o600)
            topic, payload = sent[0]
            self.assertEqual(topic, f"sensors/{DEV}/ack")
            d1 = idm.verify_ack(payload.encode(), DEV, 3, {br.ack_pk: "self"})
            self.assertEqual(d1["seq"], 9)
            # the same key after a restart
            pk = br.ack_pk
            self.assertEqual(b.Bridge(cfg).ack_pk, pk)

    def test_unsigned_mode_still_names_the_device(self):
        br = b.Bridge(b.load_config(None))
        sent = []
        br._publish = lambda t, p, **k: sent.append(p)
        br._ack(DEV, {"v": 2, "epoch": 3, "seq": 9})
        self.assertEqual(json.loads(sent[0])["id"], DEV)
        self.assertNotIn("sig", sent[0])


class FakeCse:
    def __init__(self, latest=None, down=False):
        self.latest, self.down, self.reads = latest, down, 0

    def hier(self, *names):
        return "/".join(names)

    def latest_at(self, url):
        self.reads += 1
        if self.down:
            raise b.CseUnavailable("down")
        return self.latest


class ReplayFloor(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.sk = Ed25519PrivateKey.from_private_bytes(SEED)
        self.chain = FakeChain()
        self.chain.entries[idm.sui_address(idm.public_bytes(self.sk))] = {
            "cse_id": DEV, "role": 3, "registered_at_ms": "1"}

    def tearDown(self):
        self.dir.cleanup()

    def bridge(self, cse=None, state=True, refresh="60"):
        cfg = b.load_config(None)
        cfg["identity"]["mode"] = "require"
        cfg["identity"]["registry_id"] = "0xreg"
        cfg["identity"]["graphql_url"] = "http://127.0.0.1:9/graphql"
        cfg["identity"]["floor_refresh_s"] = refresh
        if state:
            cfg["bridge"]["state_dir"] = self.dir.name
        br = b.Bridge(cfg)
        br.registry = idm.DeviceRegistry(self.chain.post, "0xreg")
        br._publish = lambda *a, **k: None
        fake = cse or FakeCse()
        br.cse = lambda base: fake
        br.resolver.target = lambda: "http://parent"
        return br

    def send(self, br, t=T, **kw):
        br.handle(f"sensors/{DEV}/telemetry", idm.sign_obj(reading(**kw), self.sk).encode(), False, t)

    def test_floor_survives_a_restart(self):
        br = self.bridge()
        self.send(br, epoch=5, seq=1)
        br._save_replay()
        with open(os.path.join(self.dir.name, "replay.json")) as f:
            self.assertEqual(json.load(f)["devices"][DEV], {"epoch": 5, "high": 1})
        br2 = self.bridge()                       # restarted, empty CSE: only the file knows
        self.send(br2, epoch=4, seq=99)
        self.assertEqual(br2.stats["rejected:auth:stale_epoch"], 1)
        self.assertEqual(len(br2.pending), 0)

    def test_without_state_dir_a_restart_forgets(self):
        br = self.bridge(state=False)
        self.send(br, epoch=5, seq=1)
        br2 = self.bridge(state=False)
        self.send(br2, epoch=4, seq=99)
        self.assertEqual(len(br2.pending), 1)     # the regression the floor closes

    def test_epoch_increase_is_written_at_once(self):
        br = self.bridge()
        self.send(br, epoch=6, seq=0)             # no _save_replay(): raise_to saved it
        with open(os.path.join(self.dir.name, "replay.json")) as f:
            self.assertEqual(json.load(f)["devices"][DEV]["epoch"], 6)

    def test_cse_floor_rejects_a_replay_to_a_bridge_that_never_saw_the_device(self):
        cse = FakeCse(latest={"epoch": 9, "seq": 40})
        br = self.bridge(cse=cse, state=False)
        self.send(br, epoch=8, seq=3)
        self.assertEqual(br.stats["rejected:auth:stale_epoch"], 1)
        self.assertEqual(br.stats["floor_cse_reads"], 1)
        self.send(br, epoch=9, seq=41)            # the current epoch passes
        self.assertEqual(len(br.pending), 1)

    def test_cse_floor_is_cached_then_refreshed(self):
        cse = FakeCse(latest={"epoch": 9, "seq": 40})
        br = self.bridge(cse=cse, state=False, refresh="60")
        self.send(br, epoch=9, seq=41)
        self.send(br, t=T + 10, epoch=9, seq=42)
        self.assertEqual(cse.reads, 1)
        cse.latest = {"epoch": 10, "seq": 0}      # the device moved on, via another bridge
        self.send(br, t=T + 61, epoch=9, seq=43)
        self.assertEqual(cse.reads, 2)
        self.assertEqual(br.stats["rejected:auth:stale_epoch"], 1)

    def test_cse_down_keeps_the_local_floor_and_retries_soon(self):
        cse = FakeCse(down=True)
        br = self.bridge(cse=cse)
        self.send(br, epoch=5, seq=1)
        self.assertEqual(len(br.pending), 1)
        self.send(br, t=T + 2, epoch=5, seq=2)
        self.assertEqual(cse.reads, 1)            # backed off
        self.send(br, t=T + 6, epoch=4, seq=2)
        self.assertEqual(cse.reads, 2)            # retried after ~5 s
        self.assertEqual(br.stats["rejected:auth:stale_epoch"], 1)

    def test_seq_window_in_the_current_epoch(self):
        br = self.bridge()
        self.send(br, epoch=5, seq=1000)
        self.send(br, epoch=5, seq=1000 - 200)    # a resend within the window: accepted
        self.send(br, epoch=5, seq=1000 - 300)    # older than the board could resend: replay
        self.assertEqual(len(br.pending), 2)
        self.assertEqual(br.stats["rejected:auth:stale_seq"], 1)

    def test_corrupt_state_file_is_moved_aside(self):
        with open(os.path.join(self.dir.name, "replay.json"), "w") as f:
            f.write("{not json")
        br = self.bridge(cse=FakeCse(latest={"epoch": 7, "seq": 1}))
        self.assertTrue(os.path.exists(os.path.join(self.dir.name, "replay.json.corrupt")))
        self.send(br, epoch=6, seq=1)             # the CSE floor still applies
        self.assertEqual(br.stats["rejected:auth:stale_epoch"], 1)

    def test_unauthenticated_messages_never_move_the_floor(self):
        br = self.bridge()
        rogue = Ed25519PrivateKey.generate()
        br.handle(f"sensors/{DEV}/telemetry", idm.sign_obj(reading(epoch=99), rogue).encode(), False, T)
        br.handle(f"sensors/{DEV}/telemetry", json.dumps(reading(epoch=99)).encode(), False, T)
        self.assertIsNone(br.replay.get(DEV))
        self.send(br, epoch=5, seq=1)
        self.assertEqual(len(br.pending), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
