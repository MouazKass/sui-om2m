#!/usr/bin/env python3
"""
chain_sim.py - an in-memory stand-in for the v8 Sui package, for offline testing.

It is NOT Sui. It replays the decision logic of the deployed Move modules, in
the same order and with the same abort codes, so the DAS flow can be exercised
without a wallet, gas or testnet:

  step 1  identity::verify           E_NOT_REGISTERED   (identity 1)
  step 2  trust::require_min         E_NOT_FOUND (1), E_TRUST_TOO_LOW (2)   min = sui.min.trust (50)
  step 3  cap_token::validate_for_use E_RESOURCE_MISMATCH (3), E_OP_NOT_ALLOWED (4),
                                      E_TOKEN_EXPIRED (1), E_TOKEN_EXHAUSTED (2)
  step 4  policy::evaluate           E_POLICY_MISSING (1), E_TRUST_BELOW_MIN (3),
                                      E_OP_DENIED (2), E_IN_BLACKOUT (4)
  step 5+6 evaluator::decide_and_log  audit record, token use +1

v8 specifics: the requester is the signer, and the token must be owned by it
(A3/A4); a DENY is found by a free simulation and never submitted (F3), so it
costs no gas. The response says so with "paid": false.

Atomicity: nothing is mutated unless all steps pass (a PTB abort rolls back
everything, including step 3's use counter). Denials are logged separately,
like evaluator::log_denied.

Simulated latency: by default each decision waits ~1.3 s, the measured native-path
mean on the testbed (Evaluation, n=200). Use --latency-ms 0 for fast tests.

HTTP API (used by mock_cse's DAS and by the dashboard):
  POST /evaluate   {"requester","token","rid","op"} -> {"granted", "label", "digest"?, "elapsed_ms"}
  POST /admin/*    register | set_trust | set_policy | mint      (stand-ins for the admin-cap calls)
  GET  /state
"""

import argparse
import hashlib
import itertools
import json
import threading
import time

from flask import Flask, jsonify, request

app = Flask(__name__)
LOCK = threading.Lock()
SEQ = itertools.count(1)
L = {"identity": {}, "trust": {}, "policies": {}, "tokens": {}, "audit": [], "latency_ms": 1300,
     "stats": {"grant_submitted": 0, "deny_simulated": 0}}


class Abort(Exception):
    def __init__(self, module, name, code):
        super().__init__(f"{module}::{name}(abort {code})")
        self.label = str(self)


def now_ms():
    return int(time.time() * 1000)


def obj_id(*parts):
    return "0x" + hashlib.sha256(("|".join(map(str, parts)) + str(next(SEQ))).encode()).hexdigest()


def decide(requester, token_id, rid, op):
    """Pure check of steps 1-4. Raises Abort, returns trust on success."""
    tok = L["tokens"].get(token_id)
    if tok is None or tok["owner"] != requester:
        # on Sui this fails at the signature/ownership check, before any Move code runs
        raise Abort("rpc", "not signed by the correct sender", 0)
    if requester not in L["identity"]:
        raise Abort("identity", "E_NOT_REGISTERED", 1)
    if requester not in L["trust"]:
        raise Abort("trust", "E_NOT_FOUND", 1)
    trust = L["trust"][requester]
    if trust < L["min_trust"]:
        raise Abort("trust", "E_TRUST_TOO_LOW", 2)
    if tok["rid"] != rid:
        raise Abort("cap_token", "E_RESOURCE_MISMATCH", 3)
    if tok["ops"] & op != op:
        raise Abort("cap_token", "E_OP_NOT_ALLOWED", 4)
    if now_ms() >= tok["expiry_ms"]:
        raise Abort("cap_token", "E_TOKEN_EXPIRED", 1)
    if tok["uses"] >= tok["max_uses"]:
        raise Abort("cap_token", "E_TOKEN_EXHAUSTED", 2)
    pol = L["policies"].get(rid)
    if pol is None:
        raise Abort("policy", "E_POLICY_MISSING", 1)
    if trust < pol["min_trust"]:
        raise Abort("policy", "E_TRUST_BELOW_MIN", 3)
    if pol["mask"] & op != op:
        raise Abort("policy", "E_OP_DENIED", 2)
    return trust


@app.post("/evaluate")
def evaluate():
    b = request.get_json(force=True)
    t0 = time.time()
    time.sleep(L["latency_ms"] / 1000.0)
    with LOCK:
        try:
            trust = decide(b["requester"], b["token"], b["rid"], int(b["op"]))
        except Abort as a:
            L["audit"].append({"t": now_ms(), "decision": 0, "requester": b["requester"],
                               "rid": b["rid"], "op": b["op"], "reason": a.label})
            L["stats"]["deny_simulated"] += 1
            return jsonify(granted=False, label=a.label, paid=False, simulated_only=True,
                           elapsed_ms=int((time.time() - t0) * 1000))
        tok = L["tokens"][b["token"]]
        tok["uses"] += 1                                  # commit (all steps passed)
        L["stats"]["grant_submitted"] += 1
        digest = obj_id("tx", b)[:46]
        L["audit"].append({"t": now_ms(), "decision": 1, "requester": b["requester"], "rid": b["rid"],
                           "op": b["op"], "trust_at_check": trust, "token_uses": tok["uses"],
                           "digest": digest})
        del L["audit"][:-200]
        return jsonify(granted=True, digest=digest, paid=True, elapsed_ms=int((time.time() - t0) * 1000))


@app.post("/admin/<what>")
def admin(what):
    b = request.get_json(force=True)
    with LOCK:
        if what == "register":
            L["identity"][b["address"]] = b.get("name", "")
            L["trust"].setdefault(b["address"], int(b.get("trust", 75)))
        elif what == "set_trust":
            L["trust"][b["address"]] = max(0, min(100, int(b["trust"])))
        elif what == "set_policy":
            L["policies"][b["rid"]] = {"min_trust": int(b.get("min_trust", 50)),
                                       "mask": int(b.get("mask", 1))}
        elif what == "mint":
            tid = obj_id("token", b)
            L["tokens"][tid] = {"owner": b["owner"], "rid": b["rid"], "ops": int(b.get("ops", 1)),
                                "expiry_ms": now_ms() + int(b.get("ttl_ms", 30 * 86400000)),
                                "max_uses": int(b.get("max_uses", 100000)), "uses": 0}
            return jsonify(token=tid)
        else:
            return jsonify(error="unknown"), 404
    return jsonify(ok=True)


@app.get("/state")
def state():
    with LOCK:
        return jsonify(json.loads(json.dumps(L)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=19000)
    ap.add_argument("--latency-ms", type=int, default=1300)
    ap.add_argument("--min-trust", type=int, default=50)
    a = ap.parse_args()
    L["latency_ms"], L["min_trust"] = a.latency_ms, a.min_trust
    import logging
    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    print(f"chain simulator on :{a.port} (latency {a.latency_ms} ms) - NOT Sui", flush=True)
    app.run(host="127.0.0.1", port=a.port, threaded=True)


if __name__ == "__main__":
    main()
