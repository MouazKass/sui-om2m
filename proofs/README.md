# Invariant proofs

Live proofs that the deployed system enforces the invariants claimed in the
paper. Each script runs against the **live v9 deployment** (package v9, types
from the v8 original id), shows the raw on-chain evidence (digests, abort
codes, object state) and ends with a `RESULT` line counting the assertions
that held.

IDs come from `deploy/v8/env.v8.sh` (generated from `deploy/v8/deployment.env`
and `deploy/v9/deployment.env`); shared helpers are in `lib_v8.sh`. No script
signs with a publisher key: admin actions go through the 3-of-5 council
(`council_do` → `scripts/v9/council.sh`, signed on each member Pi with its own
key), and node actions are signed on the node itself.

| Script | Concept | Invariants |
|---|---|---|
| `01_self_scoring.sh` | A node cannot raise its own trust | TR2 |
| `02_trust_engine.sh` | Peer scoring through the guarded path; writes bounded (|Δ| ≤ 15, ≥ 60 s apart) | TR1, TR3–TR6, TR8 |
| `03_capability_tokens.sh` | Token checked on an ordinary oneM2M RETRIEVE via DAC | CT1–CT5, A4 |
| `04_atomic_ptb.sh` | One PTB, hot-potato receipt chain: no skipped, reordered or forged steps | ID1–ID4, A6 |
| `05_policy.sh` | On-chain policy (min trust + ops mask), fail-closed | PO1–PO4, A5 |
| `06_failover.sh` | Lease rules, exactly one winner, live plugins converge (**moves the parent**) | FM1–FM5, FO1–FO5, A10 |
| `07_evolving_tokens.sh` | Token ops follow the owner's trust in place | EVO1–EVO7, A9 |
| `08_audit_trail.sh` | Append-only on-chain audit, no direct write path | SY1–SY5, A7 |
| `09_admin_revocation.sh` | Revoked caps can't write or mint; council-governed revocation | TR7, A1/A2/A8 |
| `10_system_logs.sh` | Plugin logs pulled from the running containers | — |

## Running

Prereqs: Git Bash on the laptop, the node SSH key (`~/.ssh/id_ed25519_suiom2m`,
override with `SSH_KEY`), the VPN (rpi4/rpi5 are reached via rpi1), and WSL
Ubuntu with the `sui` CLI for read-only queries.

```bash
proofs/run_all.sh            # interactive, pauses between concepts
BATCH=1 proofs/run_all.sh    # no pauses; exit status = number of failed proofs
PROOF_LOG=file.csv ...       # append every transaction (digest, outcome, gas)
```

`06` moves the parent role; `02`, `07` and `09` write scores, tokens or caps
but restore what they change. The latest live runs are in
`evidence/v9-rollout/proof_*.log`.

`VERIFY_FIRST.md` is a historical v7 checklist, kept for the record.
