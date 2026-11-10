#!/usr/bin/env python3
"""
mock_sui_gql.py - answers the two Sui GraphQL READS the bridge makes, for
offline tests. It is NOT Sui.

  object(address: <cluster>) { asMoveObject { contents { json } } }
      -> {"current_parent", "epoch", "lease_expires_ms", "trust_gate", "cluster_id"}
  object(address: <cluster>) { dynamicField(name: {type: <pkg>::failover::ParentPoaKey, bcs: "AA=="}) }
      -> MoveValue json = base64(PoA url)          (as live testnet returns it)
  ... ParentPoaOwnerKey -> MoveValue json = owner address (v9), or null (v8)

Response shapes are copied from a live testnet read of the v8 cluster object
(2026-11-10). Control endpoints for tests:
  POST /__set   {"parent": addr, "epoch": n, "poa": url|null, "owner": addr|null}
  POST /__fail  {"on": true|false}   (every query -> HTTP 503 while on)
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
     "cluster": "", "pkg": ""}


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
