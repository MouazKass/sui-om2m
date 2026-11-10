#!/usr/bin/env python3
"""v8_gas.py - gas per operation, read from the effects of real testnet txs.

Inputs (all in OUTDIR, produced by the v8 bench/proof scripts):
  das_decisions.csv   DAS GRANT digests (bench/bench_v8_dac.sh)
  proofs_v8.csv       every proof transaction (proofs/*.sh with PROOF_LOG)
  node_tx_digests.csv kind,digest pairs scraped from the plugin logs
                      (lease anchors, PoA publications, claims, trust writes)
Output:
  gas_per_tx.csv      kind,digest,status,checkpoint,timestamp,computation,storage,rebate,non_refundable,net
  gas_summary.csv     kind,n,net_median,net_mean,net_min,net_max,computation_median,storage_median,rebate_median

Net gas = computationCost + storageCost - storageRebate (MIST), i.e. what the
sender's balance actually lost. Read from Sui GraphQL (public testnet endpoint);
no keys, no signing.

Usage: python bench/v8_gas.py OUTDIR
"""
import csv, json, os, statistics, sys, time, urllib.request

GQL = os.environ.get("SUI_GRAPHQL", "https://graphql.testnet.sui.io/graphql")


def classify_proof(call, outcome):
    fn = call.split(":", 1)[-1]
    tag = "ok" if outcome == "success" else outcome.replace(":", "_code")
    names = {
        "trust::increase_guarded": "trust_write", "trust::decrease_guarded": "trust_write",
        "failover::claim_parent": "claim_parent", "failover::renew_lease": "renew_lease",
        "evolution::evolve": "evolve", "evolution::bootstrap": "evolve_bootstrap",
        "cap_token::mint": "token_mint", "trust::grant_admin_registered": "grant_admin",
        "trust::revoke_admin": "revoke_admin", "trust::burn_admin": "burn_admin",
        "trust::add_node": "add_node", "ptb": "ptb_attack",
    }
    for k, v in names.items():
        if fn.endswith(k):
            return f"{v}[{tag}]"
    if "DAC" in call:
        return None   # GRANT digests are taken from das_decisions.csv
    return f"{fn}[{tag}]"


def load(outdir):
    rows = []
    p = os.path.join(outdir, "das_decisions.csv")
    if os.path.exists(p):
        for r in csv.DictReader(open(p)):
            if r["decision"] == "GRANT" and r["digest"]:
                rows.append(({"1": "das_grant_read", "2": "das_grant_write"}.get(r["op"], "das_grant_op" + r["op"]), r["digest"]))
    p = os.path.join(outdir, "proofs_v8.csv")
    if os.path.exists(p):
        for r in csv.DictReader(open(p)):
            d = (r.get("digest") or "").strip()
            if not d or r["outcome"] in ("error", "deny"):
                continue
            k = classify_proof(r["call"], r["outcome"])
            if k:
                rows.append((k, d))
    p = os.path.join(outdir, "node_tx_digests.csv")
    if os.path.exists(p):
        for r in csv.DictReader(open(p)):
            rows.append((r["kind"], r["digest"]))
    seen, out = set(), []
    for k, d in rows:
        if d not in seen:
            seen.add(d); out.append((k, d))
    return out


def query(digests):
    parts = []
    for i, d in enumerate(digests):
        parts.append(f't{i}: transaction(digest:"{d}"){{ digest effects{{ status timestamp checkpoint{{sequenceNumber}} '
                     f'gasEffects{{ gasSummary{{ computationCost storageCost storageRebate nonRefundableStorageFee }} }} }} }}')
    body = json.dumps({"query": "{ " + " ".join(parts) + " }"}).encode()
    for attempt in range(4):
        try:
            req = urllib.request.Request(GQL, data=body, headers={"Content-Type": "application/json"})
            data = json.loads(urllib.request.urlopen(req, timeout=30).read())["data"]
            return [data[f"t{i}"] for i in range(len(digests))]
        except Exception as e:  # transient endpoint errors
            if attempt == 3:
                raise
            time.sleep(2 * (attempt + 1))


def main(outdir):
    rows = load(outdir)
    res = []
    for i in range(0, len(rows), 20):
        chunk = rows[i:i + 20]
        for (k, d), t in zip(chunk, query([d for _, d in chunk])):
            if not t:
                res.append([k, d, "NOT_FOUND"] + [""] * 7); continue
            e = t["effects"]; g = e["gasEffects"]["gasSummary"]
            c, s, r, nr = (int(g[x]) for x in ("computationCost", "storageCost", "storageRebate", "nonRefundableStorageFee"))
            res.append([k, d, e["status"], e["checkpoint"]["sequenceNumber"], e["timestamp"], c, s, r, nr, c + s - r])
    with open(os.path.join(outdir, "gas_per_tx.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["kind", "digest", "status", "checkpoint", "timestamp", "computation", "storage", "rebate", "non_refundable", "net"])
        w.writerows(res)
    by = {}
    for r in res:
        if r[2] in ("SUCCESS", "FAILURE"):
            by.setdefault(r[0], []).append(r)
    with open(os.path.join(outdir, "gas_summary.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["kind", "n", "net_median", "net_mean", "net_min", "net_max", "computation_median", "storage_median", "rebate_median"])
        for k in sorted(by):
            v = by[k]; net = [x[9] for x in v]
            w.writerow([k, len(v), int(statistics.median(net)), round(statistics.mean(net)), min(net), max(net),
                        int(statistics.median(x[5] for x in v)), int(statistics.median(x[6] for x in v)), int(statistics.median(x[7] for x in v))])
    print(open(os.path.join(outdir, "gas_summary.csv")).read())
    nf = sum(1 for r in res if r[2] == "NOT_FOUND")
    print(f"{len(res)} transactions read ({nf} not found)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "evidence/v8-measurements")
