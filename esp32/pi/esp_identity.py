"""
esp_identity.py - per-device identity for ESP32 sensors (signing + on-chain lookup).

Every sensor holds its own Ed25519 keypair, generated ON the device (NVS on an
ESP32; a 0600 key file on the Pi that runs a simulator) and never copied off.
Its on-chain identity is the Sui address of that key,

    address = blake2b-256( 0x00 || public_key )      (Sui's Ed25519 scheme flag)

registered in the om2m_access::identity registry by a 3-of-5 council vote
(scripts/v9/council.sh id-register <addr> <device-id> 3), role ROLE_AE = 3, with
cse_id = the device id. Deregistering it (council id-deregister) revokes it.
No Move change was needed: the registry already stores (address -> cse_id, role).

Wire format. A signed message is the device's usual JSON object with two extra
fields: "pk" (hex public key, anywhere in the object) and "sig", which must be
the LAST field:

    {"v":2,"id":"esp32-dht-01","pk":"<64 hex>",...,"humidity":40.0,"sig":"<128 hex>"}

The signature covers the exact bytes of the object WITHOUT the sig field
(i.e. everything before ',"sig":"' plus the closing '}'), prefixed by a domain
tag, so no JSON canonicalisation is needed on the ESP32:

    sig = Ed25519.sign(sk, DOMAIN || body_bytes)

The verifier also checks that the full message, minus "sig", parses to exactly
the same object as the signed body, so nothing outside the signature can change
what the bridge stores.

Crypto: python3-cryptography (Debian package, already on every testbed Pi);
the firmware uses libsodium (crypto_sign_detached / crypto_generichash), which
the ESP32 Arduino core ships. Both are RFC 8032 Ed25519.
"""

import base64
import hashlib
import json
import os
import threading
import time

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (Ed25519PrivateKey,
                                                               Ed25519PublicKey)

DOMAIN = b"om2m-esp32-sig-v1\x00"
ACK_DOMAIN = b"om2m-esp32-ack-v1\x00"     # bridge -> sensor acks (never a device message)
SIG_FIELD = b',"sig":"'
ROLE_AE = 3


class IdentityError(Exception):
    """A message failed device authentication. The message is the reason code."""


# ---------------------------------------------------------------------------
# keys and addresses
# ---------------------------------------------------------------------------
def sui_address(pk: bytes) -> str:
    if len(pk) != 32:
        raise ValueError("Ed25519 public key must be 32 bytes")
    return "0x" + hashlib.blake2b(b"\x00" + pk, digest_size=32).hexdigest()


def public_bytes(sk: Ed25519PrivateKey) -> bytes:
    return sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def load_or_create_key(path: str) -> Ed25519PrivateKey:
    """32-byte seed (hex) in a 0600 file, created on first use. Never leaves the host."""
    try:
        with open(path) as f:
            seed = bytes.fromhex(f.read().strip())
    except FileNotFoundError:
        os.makedirs(os.path.dirname(os.path.abspath(path)), mode=0o700, exist_ok=True)
        seed = os.urandom(32)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(seed.hex() + "\n")
    if len(seed) != 32:
        raise ValueError(f"{path}: expected a 32-byte hex seed")
    return Ed25519PrivateKey.from_private_bytes(seed)


# ---------------------------------------------------------------------------
# signing / verification
# ---------------------------------------------------------------------------
def sign_body(body: str, sk: Ed25519PrivateKey, domain: bytes = DOMAIN) -> str:
    """body: a compact JSON object (already containing "pk") -> signed message."""
    if not body.endswith("}") or '"sig"' in body:
        raise ValueError("body must be a JSON object without a sig field")
    sig = sk.sign(domain + body.encode("utf-8"))
    return body[:-1] + ',"sig":"' + sig.hex() + '"}'


def sign_obj(obj: dict, sk: Ed25519PrivateKey) -> str:
    obj = dict(obj)
    obj["pk"] = public_bytes(sk).hex()
    return sign_body(json.dumps(obj, separators=(",", ":")), sk)


def split_signed(raw: bytes):
    """-> (signed_body_bytes, sig_bytes). Raises IdentityError('unsigned'|'bad_sig_format')."""
    i = raw.rfind(SIG_FIELD)
    if i < 0:
        raise IdentityError("unsigned")
    tail = raw[i + len(SIG_FIELD):]
    if len(tail) != 128 + 2 or not tail.endswith(b'"}'):
        raise IdentityError("bad_sig_format")
    try:
        sig = bytes.fromhex(tail[:128].decode("ascii"))
    except (UnicodeDecodeError, ValueError):
        raise IdentityError("bad_sig_format")
    return raw[:i] + b"}", sig


def verify_message(raw: bytes, msg: dict, domain: bytes = DOMAIN, pk_field: str = "pk") -> bytes:
    """Check msg (the parsed raw) is signed by the key in msg[pk_field]. Returns the pk."""
    body, sig = split_signed(raw)
    pk_hex = msg.get(pk_field)
    if not (isinstance(pk_hex, str) and len(pk_hex) == 64):
        raise IdentityError("bad_pk")
    try:
        pk = bytes.fromhex(pk_hex)
    except ValueError:
        raise IdentityError("bad_pk")
    try:
        Ed25519PublicKey.from_public_bytes(pk).verify(sig, domain + body)
    except (InvalidSignature, ValueError):
        raise IdentityError("bad_signature")
    try:
        signed = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise IdentityError("bad_signed_body")
    rest = {k: v for k, v in msg.items() if k != "sig"}
    if signed != rest:
        raise IdentityError("body_mismatch")
    return pk


# ---------------------------------------------------------------------------
# signed acknowledgements (bridge -> sensor)
# ---------------------------------------------------------------------------
# A bridge acknowledges each stored reading on sensors/<device>/ack. An unsigned
# ack let anyone on the broker make a board drop an unstored reading from its
# resend buffer (and hide a dead bridge from its no-ack failover). Each bridge
# therefore signs its acks with its own Ed25519 "ack key", generated on its Pi
# (/var/lib/om2m-ipe-bridge/ack.key, 0600, owned by the bridge's user) and
# never copied. The board accepts an ack only if
#   * "apk" is one of the ack keys pinned on it (firmware ACK_TRUSTED_KEYS /
#     simulator --ack-keys; the public keys are kept in deploy/v9/ack_keys/),
#   * sig = Ed25519(ack key, ACK_DOMAIN || <ack without the sig field>) verifies,
#   * "id" is the board's own device id and "epoch" its current epoch.
# The ack names (device, epoch, seq), so replaying an old valid ack only
# re-confirms a reading that bridge did store. Distinct domain tags keep a
# device signature from ever being accepted as an ack and vice versa.
#
#   {"id":"esp32-dht-01","epoch":7,"seq":42,"node":"rpi2","ts":1762800000,
#    "apk":"<64 hex>","sig":"<128 hex>"}


def sign_ack(fields: dict, sk: Ed25519PrivateKey) -> str:
    obj = dict(fields)
    obj["apk"] = public_bytes(sk).hex()
    return sign_body(json.dumps(obj, separators=(",", ":")), sk, ACK_DOMAIN)


def load_trusted_ack_keys(path: str) -> dict:
    """Lines '<label> <64-hex pk>' (# comments) -> {pk_hex: label}."""
    out = {}
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].split()
            if not line:
                continue
            pk = line[-1].lower()
            if len(pk) != 64:
                raise ValueError(f"{path}: bad ack key line {line}")
            bytes.fromhex(pk)
            out[pk] = line[0] if len(line) > 1 else pk[:8]
    return out


def verify_ack(raw: bytes, device: str, epoch, trusted: dict) -> dict:
    """-> the verified ack dict. IdentityError(reason) unless it is a genuine ack
    for this device and epoch, signed by a pinned bridge key."""
    try:
        msg = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise IdentityError("ack_malformed")
    if not isinstance(msg, dict):
        raise IdentityError("ack_malformed")
    apk = msg.get("apk")
    if not (isinstance(apk, str) and apk.lower() in trusted):
        raise IdentityError("ack_untrusted_key" if apk else "ack_unsigned")
    verify_message(raw, msg, domain=ACK_DOMAIN, pk_field="apk")
    if msg.get("id") != device:
        raise IdentityError("ack_wrong_device")
    if msg.get("epoch") != epoch:
        raise IdentityError("ack_wrong_epoch")
    if not (isinstance(msg.get("seq"), int) and not isinstance(msg.get("seq"), bool)):
        raise IdentityError("ack_malformed")
    return msg


# ---------------------------------------------------------------------------
# on-chain registry (read-only GraphQL)
# ---------------------------------------------------------------------------
Q_OBJECT = "query($id:SuiAddress!){ object(address:$id){ asMoveObject { contents { json } } } }"
Q_ENTRY = ("query($id:SuiAddress!,$bcs:Base64!){ address(address:$id){"
           " dynamicField(name:{type:\"address\", bcs:$bcs}){ value { __typename ... on MoveValue { json } } } } }")


class DeviceRegistry:
    """Answers "is <address> a registered, active end device called <device>?"

    Reads om2m_access::identity::Registry.nodes (a Table<address, Node>) over
    GraphQL; no signing, no gas. Answers are cached: positive for ttl_s,
    negative for negative_ttl_s, so a council deregistration takes effect
    within ttl_s. If the chain cannot be read, a positive answer younger than
    max_stale_s is reused; otherwise the message is rejected (fail closed).
    """

    def __init__(self, post, registry_id, ttl_s=60.0, negative_ttl_s=15.0, max_stale_s=300.0,
                 clock=time.time):
        self.post = post                       # post(query, variables) -> data dict
        self.registry_id = registry_id
        self.ttl_s, self.neg_s, self.stale_s = ttl_s, negative_ttl_s, max_stale_s
        self.clock = clock
        self.table_id = None
        self.cache = {}                        # addr -> (entry|None, fetched_at)
        self.lock = threading.Lock()
        self.reads = 0

    def _table(self):
        if self.table_id is None:
            d = self.post(Q_OBJECT, {"id": self.registry_id})
            j = ((((d.get("object") or {}).get("asMoveObject") or {}).get("contents") or {})
                 .get("json") or {})
            tid = (j.get("nodes") or {}).get("id")
            if not tid:
                raise RuntimeError("identity registry has no nodes table")
            self.table_id = tid
        return self.table_id

    def _fetch(self, addr):
        self.reads += 1
        bcs = base64.b64encode(bytes.fromhex(addr[2:])).decode()
        d = self.post(Q_ENTRY, {"id": self._table(), "bcs": bcs})
        df = ((d.get("address") or {}).get("dynamicField") or {})
        val = (df.get("value") or {})
        return val.get("json") if val.get("__typename") == "MoveValue" else None

    def lookup(self, addr):
        """-> entry dict {cse_id, role, registered_at_ms} or None. Raises IdentityError
        ('identity_unavailable') when the chain is unreadable and nothing usable is cached."""
        now = self.clock()
        with self.lock:
            hit = self.cache.get(addr)
        if hit:
            entry, at = hit
            if now - at < (self.ttl_s if entry else self.neg_s):
                return entry
        try:
            entry = self._fetch(addr)
        except Exception:
            if hit and hit[0] and now - hit[1] < self.stale_s:
                return hit[0]
            raise IdentityError("identity_unavailable")
        with self.lock:
            self.cache[addr] = (entry, now)
        return entry

    def check(self, device, pk: bytes) -> str:
        """Device authorised -> its address. Else IdentityError(reason)."""
        addr = sui_address(pk)
        entry = self.lookup(addr)
        if entry is None:
            raise IdentityError("device_not_registered")
        try:
            role = int(entry.get("role"))
        except (TypeError, ValueError):
            role = -1
        if role != ROLE_AE:
            raise IdentityError("device_wrong_role")
        if entry.get("cse_id") != device:
            raise IdentityError("device_id_mismatch")
        return addr
