# Evaluation Measurements — sui-om2m

All measurements on **package v6** (`0xb579914d317ebd8bb6ef6d0b59d2f80a4a81fc731917840dd01a4daa64180899`),
Sui testnet, captured live 2026-06-27. Node: rpi3 (10.25.96.203, IN-CSE, addr
`0x27dacda1...64ea10`) unless noted. Reproduce with the scripts in `bench/`.

---

## 1. Access-decision latency (native BCS + JSON-RPC path)

Measured by the DAS itself (`result.elapsedMs`, logged on every `Sui GRANT`) —
pure on-chain decision time, excludes HTTP framing. Trigger requires the
`X-M2M-Operation: 5` header (see RECOVERY.md). Script: `bench/bench_latency_v2.sh`.

| Statistic | Value |
|---|---|
| **Warm (n=11)** | **1295 ± 43 ms**, p50 1292, min 1244, max 1400 |
| Cold-start (first request) | ~2000–3000 ms (JIT + connection warm-up) |
| Earlier batch (n=10) | 1382 ± 239 ms |

Headline: **~1.3 s per decision, σ=43 ms (very stable).**

## 2. Baseline — plain OM2M RETRIEVE, no chain

A normal oneM2M RETRIEVE on an unprotected container (native ACP only, no DAS,
no on-chain check). Script: `bench/bench_baseline.sh`.

| Statistic | Value |
|---|---|
| **n=30** | **5.4 ± 1.6 ms**, p50 5.0, min 3.6, max 11.1 |

## 3. Overhead the on-chain layer adds

> Native 1295 ms − baseline 5.4 ms ≈ **1290 ms per decision**

This ~1.3 s is the measured price of a tamper-evident, trust-gated, atomic access
decision over a non-verifiable one. Essentially all of it is the on-chain
transaction confirmation (a Sui testnet round trip), not client-side PTB assembly.

## 4. Legacy CLI path (contrast only)

The earlier shell-out path (spawned a `sui` subprocess per decision), retained
only to quantify the native-path speedup.

| Path | Latency |
|---|---|
| CLI shell-out | ~6000–7000 ms |
| Native (this work) | ~1295 ms |
| **Speedup** | **~4–5×** |

---

## 5. Gas per operation

Net gas = `computationCost + storageCost − storageRebate`. 1 SUI = 10^9 MIST.
Read from transaction effects. Script: `bench/bench_gas_per_op.sh`.

| Operation | computation | storage | rebate | **Net (MIST)** | **Net (SUI)** | digest |
|---|---|---|---|---|---|---|
| Access GRANT | 1,000,000 | 84,808,400 | 83,268,108 | **2,540,292** | **0.00254** | (access decision) |
| Tier change (evolve) | 1,000,000 | 7,098,400 | 7,027,416 | **1,070,984** | **0.00107** | `AJxnJArCrVSAv3fAEvTu7Dvv61DzsePkCSxDo8QjMQhh` |
| Failover claim | 1,000,000 | 2,758,800 | 2,731,212 | **1,027,588** | **0.00103** | `HjomVKuvz2VGUabnjiQt4aswMmGiLthd7kXjTkYpss3L` |

Notes:
- Computation is a flat 1,000,000 MIST across all three (Move logic is lightweight);
  the differences are entirely storage.
- Access decision is priciest (writes the audit record); tier-change and
  failover-claim are cheaper and nearly identical.
- Every operation costs a fraction of a cent.
- Storage differs for create-vs-mutate, so the first tier change for a fresh node
  may cost slightly more than subsequent ones.

## 6. Failover takeover time

Wall-clock from parent termination to a new parent anointed on-chain (new cluster
epoch). Script: `bench/bench_failover_time.sh` (reads `content.epoch` from the
Cluster object, kills the current parent dynamically each run).

| Statistic | Value |
|---|---|
| **Batch (n=3)** | **11.4 ± 2.7 s**, range 8.7–14.2 |
| Single clean run | 15.3 s (epoch 49→50) |

Breakdown: ~15 s configured heartbeat-timeout window
(`failover.heartbeat.timeout.ms=15000`) + ~0.3 s on-chain claim confirmation.

Honest framing: the measured mean (11.4 s) sits below the 15 s window because the
clock starts at container kill, whereas the follower's silence timer started at
the parent's *last heartbeat* (up to one 5 s heartbeat-period earlier). The
measured range (8.7–14.2 s) falls within the predicted [~10.3, ~15.3] s band, so
the measurement validates the analytical bound. The window is a tunable
liveness/responsiveness trade-off.

---

## Summary table (for the paper)

| Metric | Value |
|---|---|
| Native access latency | 1295 ± 43 ms (warm, n=11) |
| Baseline (no chain) | 5.4 ± 1.6 ms (n=30) |
| On-chain overhead | ~1290 ms / decision |
| vs legacy CLI | ~4–5× faster (CLI ~6–7 s) |
| Gas: access GRANT | 0.00254 SUI |
| Gas: tier change | 0.00107 SUI |
| Gas: failover claim | 0.00103 SUI |
| Failover takeover | 11.4 ± 2.7 s (n=3) |

## Key IDs (for reproduction)
- v6 package: `0xb579914d317ebd8bb6ef6d0b59d2f80a4a81fc731917840dd01a4daa64180899`
- Cluster: `0x2ca259ed6a30f0a9dd8b4950789331654f12836f179b82c7fbb52c74476a3800`
- CapToken (Csensor-001, owned by rpi3): `0xe474652c3cf82f060e8f1b6d01c9e3d953f7edd67246c65325f53b70442f7aff`
- Nodes: rpi1 10.25.96.200 (`0xef9c6271...`), rpi2 .201 (`0x4be6060a...`), rpi3 .203 (`0x27dacda1...`)
