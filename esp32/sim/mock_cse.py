#!/usr/bin/env python3
"""
mock_cse.py - a small oneM2M CSE emulator for testing the bridge WITHOUT a Pi.

It is NOT Eclipse OM2M. It reproduces the parts of OM2M's HTTP binding, and of
the v8 testbed's DAS wiring, that the bridge relies on. Each behaviour cites
where it was established:

  * addressing  /~/<cse-id>, /~/<cse-id>/<cse-name>/<rn>/..., /~/<cse-id>/<ri>,
                .../la .../ol on containers
  * POST ty=2|3|4 (AE, container, contentInstance), PUT on AE (lbl), DELETE
  * ri style    /<cse-id>/CAE<n>, cnt-<n>, cin-<n>; an AE created by an
                originator starting with "C" gets ri /<cse-id>/<originator>
                (AEController, C2_FINDINGS.md 3.4)
  * 409 when a child of the same parent already has that rn (including
    contentInstances: the bridge's exactly-once storage relies on it)
  * mni         oldest contentInstance removed when a container is full
  * state is in memory: killing and restarting wipes every resource, and
    acp ris are regenerated (RECOVERY.md)
  * ACPs (provision-das.sh, v8):
      acp_admin    grants admin:admin everything
      acp_sui_dac  grants admin:admin everything, nobody else
      sui-dac      <dynamicAuthorizationConsultation> (ty=34) -> sui-das
    A request by an originator the static ACP does not grant, on an AE whose
    daci names sui-dac, is referred to the DAS (Controller.checkPermissions
    -> DynamicAuthorizationSelector). Containers and contentInstances are
    NEVER referred (ContainerController calls checkACP only, C2_FINDINGS 3.1).
  * a resource created WITHOUT acpi rejects its own UPDATE/DELETE (403)

Run:  python3 mock_cse.py --port 8282 --chain-url http://127.0.0.1:19000 --mappings m.properties
"""

import argparse
import itertools
import json
import logging
import random
import threading
import time

from flask import Flask, Response, request

app = Flask(__name__)
LOCK = threading.Lock()
CFG = {}
RES = {}          # ri -> resource dict
COUNTER = itertools.count(random.randint(100000000, 500000000))
TY_KEY = {1: "m2m:acp", 2: "m2m:ae", 3: "m2m:cnt", 4: "m2m:cin", 5: "m2m:cb", 34: "m2m:dac"}
ALLOWED_PARENT = {2: {5}, 3: {2, 3, 5}, 4: {3}}
ADMIN_ACPS = set()     # ris of ACPs that grant admin:admin (acp_admin, acp_sui_dac)


def now_ts():
    return time.strftime("%Y%m%dT%H%M%S", time.gmtime())


def reply(code, rsc, body=None):
    r = Response(json.dumps(body) if body is not None else "", status=code,
                 mimetype="application/json")
    r.headers["X-M2M-RSC"] = str(rsc)
    if "X-M2M-RI" in request.headers:
        r.headers["X-M2M-RI"] = request.headers["X-M2M-RI"]
    return r


def err(code, rsc, text):
    return reply(code, rsc, {"m2m:dbg": text})


def public(res):
    out = {k: v for k, v in res.items() if not k.startswith("_")}
    return {TY_KEY[res["ty"]]: out}


def _add(parent, res):
    RES[res["ri"]] = res
    RES[parent]["_children"].append(res["ri"])
    return res["ri"]


def init_cse():
    """A fresh boot: CSEBase + acp_admin, then what sui-das-provision.service
    creates (sui-das AE, acp_sui_dac, sui-dac) unless --no-dac."""
    RES.clear()
    ADMIN_ACPS.clear()
    root = f"/{CFG['cse_id']}"
    RES[root] = {"ty": 5, "ri": root, "rn": CFG["cse_name"], "csi": root, "cst": 1,
                 "ct": now_ts(), "lt": now_ts(), "_children": []}
    pv = {"acr": [{"acor": [CFG["originator"], root], "acop": 63}]}
    acp = _add(root, {"ty": 1, "ri": f"{root}/acp-{next(COUNTER)}", "rn": "acp_admin", "pi": root,
                      "ct": now_ts(), "pv": pv, "_children": []})
    ADMIN_ACPS.add(acp)
    if CFG.get("with_dac"):
        das = _add(root, {"ty": 2, "ri": f"{root}/CAE{next(COUNTER)}", "rn": CFG["das_apoc"], "pi": root,
                          "api": "N.sui-das.0001", "rr": True, "poa": [CFG["das_apoc"]], "acpi": [acp],
                          "ct": now_ts(), "lt": now_ts(), "_children": []})
        acpd = _add(root, {"ty": 1, "ri": f"{root}/acp-{next(COUNTER)}", "rn": "acp_sui_dac", "pi": root,
                           "ct": now_ts(), "pv": pv, "pvs": pv, "_children": []})
        ADMIN_ACPS.add(acpd)
        _add(root, {"ty": 34, "ri": f"{root}/dac-{next(COUNTER)}", "rn": "sui-dac", "pi": root,
                    "dae": True, "dap": [das], "acpi": [acp], "ct": now_ts(), "_children": []})


def children(ri):
    return [RES[c] for c in RES[ri]["_children"] if c in RES]


def resolve(path):
    """Returns (resource, virtual) where virtual is None|'la'|'ol'."""
    parts = [p for p in path.split("/") if p]
    if not parts or parts[0] != CFG["cse_id"]:
        return None, None
    cur = RES[f"/{CFG['cse_id']}"]
    rest = parts[1:]
    if rest and rest[0] == CFG["cse_name"]:
        rest = rest[1:]                       # hierarchical
        for i, name in enumerate(rest):
            if name in ("la", "ol") and i == len(rest) - 1 and cur["ty"] == 3:
                return cur, name
            match = [c for c in children(cur["ri"]) if c["rn"] == name]
            if not match:
                return None, None
            cur = match[0]
        return cur, None
    if rest:                                  # by resource id
        ri = f"/{CFG['cse_id']}/{rest[0]}"
        if ri not in RES:
            return None, None
        cur = RES[ri]
        if len(rest) == 2 and rest[1] in ("la", "ol") and cur["ty"] == 3:
            return cur, rest[1]
        if len(rest) > 2:
            return None, None
    return cur, None


def delete_tree(ri):
    for c in list(RES.get(ri, {}).get("_children", [])):
        delete_tree(c)
    res = RES.pop(ri, None)
    if res and res.get("pi") in RES:
        RES[res["pi"]]["_children"].remove(ri)


def admin_granted(res):
    """Static ACP check for admin:admin. Resources without acpi: CREATE/RETRIEVE
    under them works (inherited), UPDATE/DELETE of the resource itself does not."""
    acpi = res.get("acpi") or []
    return any(a in ADMIN_ACPS for a in acpi)


OP_OF = {"GET": 2, "POST": 1, "PUT": 3, "DELETE": 4}


@app.route("/~/<path:path>", methods=["GET", "POST", "PUT", "DELETE"])
def onem2m(path):
    origin = request.headers.get("X-M2M-Origin", "")
    with LOCK:
        target, virtual = resolve(path)
        if target is None:
            return err(404, 4004, "Resource not found")

        if origin != CFG["originator"]:
            # "C<x>" may register an AE under the CSEBase (no create-time check)
            if request.method == "POST" and target["ty"] == 5 and origin.startswith("C") \
                    and "ty=2" in request.headers.get("Content-Type", ""):
                return create(target, ty=2, origin=origin)
            # anything else the static ACP does not grant: only an AE (or
            # flexContainer) with daci is referred to the DAS
            if target["ty"] == 2 and target.get("daci") and not virtual:
                op = OP_OF[request.method]
                granted = consult_das(origin, target["ri"], op)
                if not granted:
                    return err(403, 4103, "ACCESS_DENIED (dynamic authorization)")
                if request.method == "GET":
                    return reply(200, 2000, public(target))
                if request.method == "DELETE":
                    delete_tree(target["ri"])
                    return reply(200, 2002)
                return err(403, 4103, "operation not emulated for dynamic grants")
            return err(403, 4103, "Access denied: static ACP, no DAS consulted")

        if request.method == "GET":
            if virtual:
                cins = [c for c in children(target["ri"]) if c["ty"] == 4]
                if not cins:
                    return err(404, 4004, "Resource not found")
                return reply(200, 2000, public(cins[-1] if virtual == "la" else cins[0]))
            return reply(200, 2000, public(target))

        if request.method == "DELETE":
            if target["ty"] in (1, 5, 34) or virtual:
                return err(400, 4000, "cannot delete")
            if not admin_granted(target):
                return err(403, 4103, "no ACP attached")
            delete_tree(target["ri"])
            return reply(200, 2002)

        if request.method == "PUT":
            if target["ty"] != 2 or virtual:
                return err(400, 4000, "PUT emulated for AE only")
            if not admin_granted(target):
                return err(403, 4103, "no ACP attached")
            try:
                attrs = json.loads(request.get_data(as_text=True))["m2m:ae"]
            except Exception:
                return err(400, 4000, "bad body")
            if "lbl" in attrs:
                target["lbl"] = list(attrs["lbl"])
            if "daci" in attrs:
                target["daci"] = list(attrs["daci"])
            target["lt"] = now_ts()
            return reply(200, 2004, public(target))

        # DAS NOTIFY (direct path, like SuiDasService behind the sui-das PoA)
        if target["ty"] == 2 and target["rn"] == CFG["das_apoc"] and CFG.get("chain_url"):
            return das_notify()

        if virtual:
            return err(400, 4000, "cannot create under virtual resource")
        ctype = request.headers.get("Content-Type", "")
        try:
            ty = int(ctype.split("ty=")[1].split(";")[0])
        except (IndexError, ValueError):
            return err(400, 4000, "missing ty in Content-Type")
        return create(target, ty)


def create(target, ty, origin=None):
    if ty not in ALLOWED_PARENT:
        return err(400, 4000, f"unsupported ty={ty}")
    if target["ty"] not in ALLOWED_PARENT[ty]:
        return err(400, 4000, f"ty={ty} not allowed under ty={target['ty']}")
    try:
        attrs = json.loads(request.get_data(as_text=True))[TY_KEY[ty]]
        assert isinstance(attrs, dict)
    except Exception:
        return err(400, 4000, "bad body")
    if ty == 2 and ("api" not in attrs or "rr" not in attrs):
        return err(400, 4000, "AE requires api and rr")
    if ty == 4 and "con" not in attrs:
        return err(400, 4000, "CIN requires con")
    acpi = attrs.get("acpi") or []
    if any(RES.get(a, {}).get("ty") != 1 for a in acpi):
        return err(400, 4000, f"acpi references unknown ACP: {acpi}")
    daci = attrs.get("daci") or []
    if any(RES.get(d, {}).get("ty") != 34 for d in daci):
        return err(400, 4000, f"daci references unknown DAC: {daci}")

    n = next(COUNTER)
    if ty == 2 and origin:
        rid = origin                     # AE-ID pinned to the C-originator
    else:
        rid = {2: "CAE", 3: "cnt-", 4: "cin-"}[ty] + str(n)
    rn = attrs.get("rn") or ({4: f"cin_{n}"}.get(ty, rid))
    if any(c["rn"] == rn for c in children(target["ri"])):
        return err(409, 4105, "Name already present in the parent collection")
    ri = f"/{CFG['cse_id']}/{rid}"
    if ri in RES:
        return err(409, 4105, "AE-ID already registered")
    res = {"ty": ty, "ri": ri, "rn": rn, "pi": target["ri"], "ct": now_ts(), "lt": now_ts(),
           "_children": []}
    if acpi and ty in (2, 3):
        res["acpi"] = acpi
    if ty == 2:
        res.update(api=attrs["api"], rr=attrs["rr"], aei=rid, lbl=attrs.get("lbl", []))
        if daci:
            res["daci"] = daci          # AEController persists daci (C2_FINDINGS 3.2)
    elif ty == 3:
        res.update(mni=int(attrs.get("mni", CFG["mni_default"])), cni=0, cbs=0, st=0,
                   lbl=attrs.get("lbl", []))
    else:
        con = attrs["con"]
        res.update(con=con, cnf=attrs.get("cnf", "text/plain:0"), cs=len(str(con)), st=0)
    RES[ri] = res
    target["_children"].append(ri)
    if ty == 4:                           # container bookkeeping + mni
        cins = [c for c in children(target["ri"]) if c["ty"] == 4]
        while len(cins) > target["mni"]:
            delete_tree(cins.pop(0)["ri"])
        target["cni"] = len(cins)
        target["cbs"] = sum(c["cs"] for c in cins)
        target["st"] += 1
    return reply(201, 2001, public(res))


# ---------------------------------------------------------------------------
# DAS emulation - mirrors plugin/.../das/SuiDasService.java (v8)
# ---------------------------------------------------------------------------
OP_MAP = {1: 2, 2: 1, 3: 2, 4: 4, 5: 1, 6: 1}   # oneM2M op -> on-chain op bit
MAPPINGS = {"addr": {}, "token": {}}            # loaded ONCE at start, like sui.mappings.properties
DASLOG = []


def load_mappings(path):
    """Same format and escaping rules as sui.mappings.properties."""
    import re
    if not path:
        return
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        return
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"((?:\\.|[^:=\\])+)\s*[:=]\s*(.*)$", line)   # first UNESCAPED : or =
        if not m:
            continue
        key, val = m.group(1).replace("\\:", ":").replace("\\=", "="), m.group(2).strip()
        if key.startswith("addr."):
            MAPPINGS["addr"][key[5:]] = val
        elif key.startswith("token.") and "::" in key[6:]:
            o, rid = key[6:].split("::", 1)
            MAPPINGS["token"][(o, rid)] = val


def daslog(line):
    DASLOG.append(time.strftime("%H:%M:%S ") + line)
    del DASLOG[:-200]


def consult_das(orig, rid, op1m2m):
    """The on-chain decision for (originator, resource ri, oneM2M op). Called
    with LOCK held; released while the 'chain' thinks."""
    import requests as rq
    if not CFG.get("chain_url"):
        daslog(f"no DAS configured: DENY originator={orig} resource={rid}")
        return False
    op = OP_MAP.get(op1m2m, 1)
    addr, tok = MAPPINGS["addr"].get(orig), MAPPINGS["token"].get((orig, rid))
    if not addr or not tok:
        daslog(f"No Sui mapping for originator={orig} resource={rid} -> DENY")
        return False
    LOCK.release()
    try:
        r = rq.post(CFG["chain_url"] + "/evaluate",
                    json={"requester": addr, "token": tok, "rid": rid, "op": op}, timeout=30).json()
    finally:
        LOCK.acquire()
    if not r["granted"]:
        daslog(f"Sui DENY originator={orig} resource={rid} op={op} err={r['label']}"
               f"{' (simulated, not submitted)' if r.get('simulated_only') else ''}")
        return False
    daslog(f"Sui GRANT originator={orig} resource={rid} op={op} digest={r['digest'][:14]}.. ({r['elapsed_ms']} ms)")
    return True


def das_notify():
    if request.headers.get("X-M2M-Operation") != "5":
        return err(403, 4103, "no ACP attached (NOTIFY needs X-M2M-Operation: 5)")
    try:
        dreq = json.loads(request.get_data(as_text=True))["m2m:sec"]["dreq"]
        orig, rid, op1m2m = dreq["or"], dreq["rid"], int(dreq.get("op", 2))
    except Exception:
        return err(400, 4102, "CONTENTS_UNACCEPTABLE")
    if not consult_das(orig, rid, op1m2m):
        return err(403, 4103, "ACCESS_DENIED")
    return reply(200, 2000, {"m2m:sec": {"sit": 2, "dresp": {"dacp": {"pv": {"acr": [
        {"acop": op1m2m, "acor": [orig]}]}}}}})


@app.route("/__daslog")
def daslog_view():
    return Response(json.dumps(DASLOG), mimetype="application/json")


@app.route("/__dump")
def dump():
    """Test helper: AEs and containers by path below the CSEBase."""
    with LOCK:
        cnts, aes = {}, {}

        def walk(ri, path):
            for c in children(ri):
                if c["ty"] in (2, 3):
                    p = f"{path}/{c['rn']}".lstrip("/")
                    if c["ty"] == 3:
                        rns = [x["rn"] for x in children(c["ri"]) if x["ty"] == 4]
                        cnts[p] = {"cni": c["cni"], "st": c["st"], "acpi": c.get("acpi", []), "rns": rns}
                    else:
                        aes[p] = {"ri": c["ri"], "acpi": c.get("acpi", []), "daci": c.get("daci", []),
                                  "lbl": c.get("lbl", [])}
                    walk(c["ri"], p)
        walk(f"/{CFG['cse_id']}", "")
        acp = {r["rn"]: r["ri"] for r in RES.values() if r["ty"] == 1}
        dac = {r["rn"]: r["ri"] for r in RES.values() if r["ty"] == 34}
        return Response(json.dumps({"containers": cnts, "aes": aes, "acp_admin": acp.get("acp_admin"),
                                    "acps": acp, "dacs": dac}), mimetype="application/json")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8282)
    ap.add_argument("--cse-id", default="in-cse")
    ap.add_argument("--cse-name", default="in-name")
    ap.add_argument("--originator", default="admin:admin")
    ap.add_argument("--mni-default", type=int, default=1000)
    ap.add_argument("--chain-url", default="", help="enable the DAS, backed by chain_sim.py")
    ap.add_argument("--mappings", default="", help="sui.mappings.properties-style file (read at start)")
    ap.add_argument("--das-apoc", default="sui-das")
    ap.add_argument("--no-dac", action="store_true",
                    help="boot without the DAC wiring (provision-das.sh not yet run)")
    a = ap.parse_args()
    CFG.update(cse_id=a.cse_id, cse_name=a.cse_name, originator=a.originator,
               mni_default=a.mni_default, chain_url=a.chain_url.rstrip("/"), das_apoc=a.das_apoc,
               with_dac=not a.no_dac)
    load_mappings(a.mappings)
    init_cse()
    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    print(f"mock CSE /~/{a.cse_id} ({a.cse_name}) on :{a.port} dac={'on' if not a.no_dac else 'off'}",
          flush=True)
    app.run(host="127.0.0.1", port=a.port, threaded=True)


if __name__ == "__main__":
    main()
