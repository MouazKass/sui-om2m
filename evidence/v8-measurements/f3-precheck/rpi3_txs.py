"""Snapshot rpi3's SUI balance and its most recent sent transactions (digest, functions called).
Usage: python rpi3_txs.py <label>   -> prints JSON line."""
import json, sys, urllib.request
ADDR = "0x27dacda1bdcb3fb8dc2a4b0d77b420deea5bb43d1047592ddadb19f35764ea10"
Q = """query($a:SuiAddress!){ address(address:$a){
  balance(coinType:"0x2::sui::SUI"){ totalBalance }
  transactions(last:8, relation:SENT){ nodes { digest
     effects { status timestamp }
     kind { __typename ... on ProgrammableTransaction { commands { nodes { __typename ... on MoveCallCommand { function { module { name } name } } } } } } } } } }"""
req = urllib.request.Request("https://graphql.testnet.sui.io/graphql",
    data=json.dumps({"query": Q, "variables": {"a": ADDR}}).encode(),
    headers={"content-type": "application/json"})
d = json.load(urllib.request.urlopen(req, timeout=30))
if "errors" in d:
    print(json.dumps(d["errors"])); sys.exit(1)
a = d["data"]["address"]
txs = []
for n in a["transactions"]["nodes"]:
    fns = []
    k = n.get("kind") or {}
    for c in ((k.get("commands") or {}).get("nodes") or []):
        f = c.get("function")
        if f: fns.append(f["module"]["name"] + "::" + f["name"])
    txs.append({"digest": n["digest"], "status": n["effects"]["status"], "ts": n["effects"]["timestamp"], "calls": fns})
print(json.dumps({"label": sys.argv[1] if len(sys.argv) > 1 else "", "balance": a["balance"]["totalBalance"], "last_sent": txs}))
