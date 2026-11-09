# BLOCKER: Sui JSON-RPC on public fullnodes is deprecated — the on-chain path is dead

Discovered 2026-11-09 on the live testbed (rpi3-iot). This supersedes every
"re-run the benchmarks" and "publish v8" task: none of them can succeed until
this is resolved.

## Symptom, observed live

`om2m-active` on rpi3 is in a continuous failing retry loop:

```
Parent silence detected (297051478 ms). Submitting Sui claim.
Claim rejected on-chain: getObject error for 0x1b6bc3b401...:
  {"code":-32601,"message":"Method not found. JSON-RPC on public fullnodes has
   been deprecated. Please migrate to gRPC or GraphQL endpoints. See
   https://docs.sui.io/develop/accessing-data/json-rpc-migration ..."}
  (digest=null)
```

Repeating roughly every 5 s (`failover.parent.selfcheck.period.ms=15000`,
`failover.heartbeat.period.ms=5000`).

## Confirmed independently, not just from the log

Against the exact endpoint the plugin defaults to
(`SuiConfig.java:74` → `https://fullnode.testnet.sui.io:443`):

| JSON-RPC method | Result |
|---|---|
| `sui_getObject` | `-32601 Method not found` (deprecated) |
| `sui_getChainIdentifier` | `-32601 Method not found` (deprecated) |
| `rpc.discover` | `-32601 Method not found` (deprecated) |

So this is not one missing method — **the entire JSON-RPC surface is gone on
public fullnodes.** Note `sui.properties` sets no `sui.rpc.url`, so the
hardcoded default above is what is actually in use.

## Blast radius

`sui.properties` on rpi3 has `sui.use.native.rpc=true`, which selects the
hand-rolled JSON-RPC path. Everything below it is therefore non-functional:

- `sdk/SuiRpcClient.java` — every call (`POST` of a JSON-RPC envelope, `SuiRpcClient.java:81`).
- `sdk/SuiObjectFetcher.java` — all on-chain object reads.
- `sdk/NativePtbBuilder.java` — native transaction submission.
- `failover/FailoverManager.java` — parent claims (observed failing above).
- **The B5b fix** from this batch (non-submitters read the real on-chain score
  instead of stamping a local EMA estimate) depends on an on-chain read, so it
  cannot work either. It is correct code on a dead transport.
- Any benchmark or proof script that reads chain state or submits a PTB.

## What this means for the paper

1. **No number currently in the paper can be re-measured until this is fixed.**
   The latency, gas and failover-time tables all depend on a working transport.
2. The existing published numbers were taken when JSON-RPC still worked, so they
   are historically valid but **not currently reproducible** — a reviewer who
   tries to reproduce them today will hit this wall. This should be stated.
3. The v8 fresh publish cannot be assumed to work until the transport question
   is settled for the CLI as well as the plugin (see below).

## Open question I could not test

Whether the `sui` CLI on the Pi (`/usr/local/bin/sui`, reported elsewhere in the
repo as `testnet-v1.73.0`) still works. The CLI is a separate code path from the
plugin's hand-rolled client:

- `ptb/PtbBuilder.java` shells out to `sui client ptb` (used when
  `sui.use.native.rpc=false`).
- `scripts/deploy_sui_package.sh` uses `sui client publish` for the v8 publish.

If that CLI build also speaks JSON-RPC internally, **the v8 publish will fail
too.** Newer CLI builds moved to gRPC. Check with, on the Pi:

```
sui --version
sui client envs
sui client object 0x1b6bc3b4010bc85fa6c021dd1b96e81747716275559b554bf258c7f88a364d38
```

A successful object read means the CLI path is still viable and can serve as the
interim transport (set `sui.use.native.rpc=false`).

## Options, cheapest first

1. **Point at a provider that still serves JSON-RPC.** Several third-party RPC
   providers continue to offer a JSON-RPC-compatible endpoint. This is a
   one-line `sui.rpc.url` addition to `sui.properties` on each Pi and needs
   **no code change** — add the property and the existing `SuiConfig` plumbing
   (`SuiConfig.java:41` `rpcUrl`) will pick it up. Verify the provider implements
   the specific methods used (`sui_getObject`, `sui_executeTransactionBlock`,
   `sui_getOwnedObjects`, …). Fastest route back to a working testbed.
2. **Fall back to the CLI path** — set `sui.use.native.rpc=false` so
   `PtbBuilder` shells out to `sui client`, *if* the CLI itself still works
   (open question above). Slower per call, which will change the latency numbers.
3. **Migrate the client to gRPC or GraphQL.** The correct long-term fix and what
   Sui directs users to. This is real work: `SuiRpcClient`, `SuiObjectFetcher`
   and `NativePtbBuilder` would all need new transports, and the BCS/PTB
   encoding in `SuiPtbEncoder` would need to be retargeted. Not a config change.

## Also observed: the broker mesh is partitioned

From rpi3, `10.25.96.200:1883` (rpi1's Mosquitto) is **not reachable**, while
`10.25.96.200:8282` (its CSE) is. The "parent silence" figure of ~297,000,000 ms
(≈ 82 hours) is consistent with gossip and heartbeats not flowing between nodes
for over three days, not with a momentary blip.

Consequences:
- Trust gossip is not being exchanged, so the trust engine has no peer
  observations to aggregate.
- The failover parent-silence detector is firing for a real reason, and would
  keep retrying even with a working RPC transport.
- **Any trust or failover measurement taken in this state is invalid.** Fix the
  mesh before re-measuring anything, independently of the RPC problem.

Check on each node: whether `mosquitto` is listening on all interfaces rather
than loopback, the bridge stanzas in `deploy/mosquitto`, and host firewall rules.
Note rpi3's own broker is reachable locally (`mqtt.broker.url=tcp://10.25.96.203:1883`),
so this is specifically about inter-node bridging.
