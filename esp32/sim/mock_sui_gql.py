#!/usr/bin/env python3
"""
mock_sui_gql.py - answers the two Sui GraphQL READS the bridge makes, for
offline tests. It is NOT Sui.

  object(address: <cluster>) { asMoveObject { contents { json } } }
      -> {"current_parent", "epoch", "lease_expires_ms", "trust_gate", "cluster_id"}
  object(address: <cluster>) { dynamicField(name: {type: <pkg>::failover::ParentPoaKey, bcs: "AA=="}) }
      -> MoveValue json = base64(PoA url)          (as live testnet returns it)
  ... ParentPoaOwnerKey -> MoveValue json = owner address (v9), or null (v8)

  object(address: <identity registry>)  -> {"id", "nodes": {"id": <table>, "size"}}
  address(address: <table>) { dynamicField(name: {type: "address", bcs}) }
      -> MoveValue json {"cse_id", "role", "registered_at_ms"} or null  (device identity)

Response shapes are copied from a live testnet read of the v8 cluster object
(2026-11-10). Control endpoints for tests:
  POST /__set   {"parent": addr, "epoch": n, "poa": url|null, "owner": addr|null}
  POST /__fail  {"on": true|false}   (every query -> HTTP 503 while on)
  POST /__reg   {"addr": a, "cse_id": s, "role": n}   (council id-register)
  POST /__dereg {"addr": a}                            (council id-deregister)
"""

import argparse
import base64
import json
import logging
import threading

from flask import Flask, Response, request

app = Flask(__name__)
LOCK = threading.Lock()
S = {"parent": "", "epoch": 0, "poa": None, "owner": None, "fail": False, "queries": 0,
     "cluster": "", "pkg": "", "registry": "0x1d", "table": "0x7ab1e", "ids": {}}


def j(body, code=200):
    return Response(json.dumps(body), status=code, mimetype="application/json")


@app.post("/graphql")
def graphql():
    with LOCK:
        S["queries"] += 1
        if S["fail"]:
            return j({"errors": [{"message": "service unavailable"}]}, 503)
        b = request.get_json(force=True)
        q, v = b.get("query", ""), b.get("variables") or {}
        vid = v.get("id", "").lower()
        if vid == S["registry"]:
            return j({"data": {"object": {"asMoveObject": {"contents": {"json": {
                "id": S["registry"], "nodes": {"id": S["table"], "size": str(len(S["ids"]))}}}}}}})
        if vid == S["table"] and "dynamicField" in q:
            addr = "0x" + base64.b64decode(v.get("bcs", "")).hex()
            e = S["ids"].get(addr)
            return j({"data": {"address": {"dynamicField":
                      {"value": {"__typename": "MoveValue", "json": e}} if e else None}}})
        if v.get("id", "").lower() != S["cluster"].lower():
            return j({"data": {"object": None}})
        if "dynamicField" in q:
            t = v.get("type", "")
            if not t.startswith(S["pkg"] + "::failover::"):
                return j({"data": {"object": {"dynamicField": None}}})
            if t.endswith("::ParentPoaKey") and S["poa"]:
                val = base64.b64encode(S["poa"].encode()).decode()
            elif t.endswith("::ParentPoaOwnerKey") and S["owner"]:
                val = S["owner"]
            else:
                return j({"data": {"object": {"dynamicField": None}}})
            return j({"data": {"object": {"dynamicField": {"value": {"__typename": "MoveValue", "json": val}}}}})
        return j({"data": {"object": {"asMoveObject": {"contents": {"json": {
            "cluster_id": "RUVfNQ==", "current_parent": S["parent"], "lease_expires_ms": "0",
            "trust_gate": "50", "epoch": str(S["epoch"])}}}}}})


@app.post("/__set")
def set_state():
    b = request.get_json(force=True)
    with LOCK:
        for k in ("parent", "epoch", "poa", "owner"):
            if k in b:
                S[k] = b[k]
    return j({"ok": True})


@app.post("/__reg")
def reg():
    b = request.get_json(force=True)
    with LOCK:
        S["ids"][b["addr"].lower()] = {"cse_id": b["cse_id"], "role": int(b.get("role", 3)),
                                       "registered_at_ms": "1"}
    return j({"ok": True})


@app.post("/__dereg")
def dereg():
    with LOCK:
        S["ids"].pop(request.get_json(force=True)["addr"].lower(), None)
    return j({"ok": True})


@app.post("/__fail")
def set_fail():
    with LOCK:
        S["fail"] = bool(request.get_json(force=True).get("on"))
    return j({"ok": True, "fail": S["fail"]})


@app.get("/__state")
def state():
    with LOCK:
        return j(dict(S))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=19100)
    ap.add_argument("--cluster", required=True)
    ap.add_argument("--pkg", required=True)
    ap.add_argument("--parent", default="")
    ap.add_argument("--poa", default="")
    ap.add_argument("--epoch", type=int, default=1)
    a = ap.parse_args()
    S.update(cluster=a.cluster, pkg=a.pkg, parent=a.parent.lower(), poa=a.poa or None, epoch=a.epoch)
    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    print(f"mock Sui GraphQL on :{a.port} - NOT Sui", flush=True)
    app.run(host="127.0.0.1", port=a.port, threaded=True)


if __name__ == "__main__":
    main()
