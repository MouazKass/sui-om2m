# ESP32 sensing layer: a sensor belongs to the cluster, not to one Pi

Status, 2026-11-10: implemented and passing every offline test (see "Verification").
It is **not yet deployed to the Pis**. Live deployment waits for the 5-node
onboarding (rpi4, rpi5) to finish. The items marked **[live]** below can only be
confirmed on real OM2M.

## 1. The problem

Hamza's v1 handover (`esp32-om2m-bridge`, credited in `AUTHORS.md`) was solid on one
node: validation, dedupe, buffering, re-provisioning after an OM2M wipe. But every
sensor was pinned to one broker IP (`MQTT_HOST "10.25.96.201"`), and its data was
pinned to that broker's own CSE. In a cluster whose whole point is surviving the loss
of a node, that is backwards:

| If ... | v1 | v2 |
|---|---|---|
| the sensor's Pi dies | the sensor is lost: it retries the dead IP forever | it fails over to the next broker within ~10 s |
| the Pi's broker is up but its bridge is down | readings are silently dropped (QoS 0, nobody subscribed) | no acks: the sensor fails over after `NO_ACK_FAILOVER_MS` |
| the parent changes | each node holds its own fragment of the data | all bridges write to the chain-named parent: one tree |
| a node is added | every sensor must be reflashed to use it | sensors learn it from a retained topic |

v1 also rested on three v7 assumptions that v8 made wrong:

1. **The device was a `<container>`.** OM2M never consults a DAS for a container:
   `ContainerController` calls `checkACP` only (`C2_FINDINGS.md` §3.1). So v1's
   "protected sensor" could never reach the chain through an ordinary request.
2. **The DAS was reached by a hand-made NOTIFY** (`gated_read.sh`). In v8 the real path
   is OM2M's own `DynamicAuthorizationConsultation`, which an ordinary RETRIEVE
   triggers.
3. **The resource key `/in-cse/in-name/<device>`** and the `sui-protected-cnt` /
   `Csensor-001` static grant. v8 removed that grant. The DAC-protected resource id
   is the non-hierarchical AE id.

## 2. The design in one picture

```
            sensors/<id>/telemetry  (epoch, seq)          sensors/<id>/ack  (per reading)
 ESP32 ───────────────────────────────▶  any Pi's Mosquitto  ◀──────────────────────────┐
   ▲  om2m/cluster/brokers (retained)          │                                         │
   │  sensors/<id>/status (session)            ▼                                         │
   │                                    that Pi's bridge ──── reads ───▶ Sui GraphQL:    │
   │                                           │               current_parent + its PoA  │
   │                                           ▼                                         │
   │                          the PARENT's OM2M:  <AE> /in-cse/C<id>  (acp_sui_dac,      │
   │                                               daci sui-dac, lbl latest=…)          │
   │                                              ├─ data/   e<epoch>-s<seq> (409 dupe) ─┘
   │                                              └─ status/ session-ordered
   └── a reader's ordinary RETRIEVE of the AE ──▶ DAC ──▶ Sui DAS on the parent ──▶ chain
```

## 3. The firmware (`firmware/esp32_sensor_node/`)

**The selector, `cluster.h`.** This is pure C++ with no Arduino calls. It is tested on a PC, and
`sim/esp32_sim.py` carries a line-by-line Python port. Both run the same
`sim/selector_vectors.txt` (27 vectors), so the firmware and the simulator cannot drift.

- **Order.** Home first, then the rest in list order. Brokers the cluster reports as
  down are tried only after every live one.
- **Bounded backoff per broker.** `base · 2^(failures−1)`, capped at `BACKOFF_MAX_MS`.
  The selector moves on to the next candidate straight away, so the time to re-attach
  is detection time plus at most `CONNECT_TIMEOUT_MS` per dead candidate.
- **Detection.** The keep-alive is 4 s, and PubSubClient drops a silent broker after one
  or two keep-alives. A crashed broker is seen at once: the connection is refused or
  reset. The TCP connect is made with a 1.5 s timeout before `mqtt.connect()`, because
  PubSubClient's own connect has none. Measured offline:
  - 1.2 s for a crashed broker;
  - about 4–8 s for a link that dies silently.
- **Return home with hysteresis.** While away, the sensor probes home every
  `HOME_PROBE_MS`. It moves back only after home has answered every probe for
  `HOME_STABLE_MS`; a single failure restarts the window. It also never returns while
  home is penalized (see the next point).
- **"Up but not acking" is a failure.** Every stored reading is acked by the bridge. If
  readings were published but none acked for `NO_ACK_FAILOVER_MS`, the bridge behind
  that broker is dead. The sensor disconnects cleanly and `penalize()`s the broker for
  3× the window, which also blocks the return home. This case was found while writing
  the cluster test; v1 had no answer to it.
- **Membership is learned.** It comes from the retained `om2m/cluster/brokers`:
  `v1;<ts>;rpi1=10.25.96.200:1883:1,…`. Seeds are never removed. A learned host is
  accepted only if it starts with `CLUSTER_ALLOW_PREFIX` (`10.25.96.`).
- **The numbering.** Each reading is numbered `(epoch, seq)`:
  - `epoch` is +1 on every power-up and stored in NVS (`Preferences`);
  - `seq` is +1 for every reading and is never reset by a reconnect.

  Readings are taken whatever the connection state. Unacknowledged ones (64 slots,
  about 5 min at a 5 s interval) are re-sent after every (re)connect.
- **Sessions.** A session is `"<epoch>.<n>"`, with n incrementing on every connection.
  The `online` presence is retained and carries the session. The Last Will carries the
  same session.
- **A planned move** clears the retained presence on the broker it leaves and sends a
  clean DISCONNECT, so that broker never fires the Last Will.

## 4. The bridge (`pi/om2m_ipe_bridge.py`)

**Where the data lives.** It goes to the cluster's current **parent**, read over Sui
GraphQL from the failover cluster object. These are the same fields `FailoverManager`
publishes:
- `current_parent` and `epoch`;
- the `ParentPoaKey` dynamic field (base64 PoA). On v9, it is ignored if
  `ParentPoaOwnerKey` names someone other than the parent.

The type-origin package id is used: `sui.package.original.id`, which stays the v8 id
after the v9 upgrade. The bridge **only reads**. It holds no key and never sends a
transaction (SY1 holds).

How it handles failures and alternatives:
- **Chain unreadable.** It keeps the last known parent. With no parent known, it
  buffers. After `local_fallback_after_s` (300 s) it writes to its own CSE rather than
  drop data.
- **Why not "local" or the "home" node.** Either would split the history across nodes
  after every failover.
- **Why not have the bridge follow the failover topic.** Since B9 every node beats, so
  heartbeats no longer say who the parent is. The chain does.
- **Optional plugin hook (not required).** A local endpoint serving the plugin's cached
  parent PoA would remove the bridge's own internet dependency. This would be a plugin
  change, so it is left to the INFRA owner (see `README.md` §6).

**The layout.** Each device is an `<AE>` created with originator `C<device>`, so its id
is pinned to `/in-cse/C<device>`. It is the same on every node, survives restarts, and
is the on-chain policy/token key. The AE carries:
- `acpi = [acp_sui_dac]`, which grants only admin, so any other originator fails the
  static check;
- `daci = [sui-dac]`.

So an ordinary RETRIEVE by a reader is decided on-chain. Data goes into `data/` and
`status/` containers. Containers can't be DAS-protected, so they carry
`acp_sui_dac` (admin only). The newest reading is mirrored into the AE label
`latest=<json>`, so a **granted RETRIEVE of the AE returns the data itself**.
`flexContainer` is the cleaner oneM2M answer, but its custom-attribute handling in this
OM2M build is unverified, so it is listed in §8, not used.

**Fail closed.** If `acp_sui_dac` or `sui-dac` is missing on the target (for example,
`provision-das.sh` has not run yet), the bridge buffers and waits. It never creates an
AE the chain does not protect. A mutation test checks this.

**Exactly once, across bridges.**
1. A per-device cache of stored `(epoch, seq)` keys drops repeats on one bridge.
2. The contentInstance name `e<epoch>-s<seq>` makes **the CSE itself** reject a second
   copy (409) when two bridges race. A 409 counts as stored.
3. Every stored or already-present reading is acked to the sensor, which then stops
   re-sending it.

Measured: across a run of every scenario, 78 readings were taken and 78 stored, with no
duplicates on any CSE.

**Session-aware presence.** A status whose session is older than the newest one stored
on the target is ignored. That is exactly the case of a Last Will fired late by a
broker the sensor already left: the one-way partition test shows it fire about 6 s
after the sensor was online elsewhere, and get ignored.

**Membership publisher.** `members_file` is the same file on every node and is re-read
when it changes. Each bridge TCP-probes every member's broker every 15 s and
republishes the retained `om2m/cluster/brokers`, plus a JSON `om2m/cluster/members` for
tools, when they change. Adding a node means adding one line to `members.conf` on every
node, with no reflash.

## 5. Failure modes, and what happens

| Failure | Detected by | Effect on data |
|---|---|---|
| home Pi powered off / broker crashed | refused/reset, or keep-alive timeout (≤ 8 s) | buffered on the sensor, re-sent on the next broker |
| one-way or flaky link | keep-alive (no PINGRESP) | as above; the late Last Will is ignored by session order |
| broker up, bridge dead | no acks for `NO_ACK_FAILOVER_MS` | buffered, re-sent; the broker is penalized |
| parent changes | the bridges' GraphQL poll (10 s) | new readings go to the new parent; history stays on the old one |
| parent's OM2M restarts (tree wiped) | 404 / connection error | bridges buffer, re-provision (fresh acp ris), replay, restore status |
| GraphQL unreachable | request error | last known parent kept |
| DAC wiring missing on the target | lookup fails | buffered until `provision-das.sh` has run (fail closed) |
| two bridges race on one reading | CSE 409 | stored once |
| sensor's NVS wiped | epoch restarts | new keys; stored readings are untouched (names differ by epoch) |
| sensor reboots | RAM buffer lost | unsent readings from before the reboot are lost (bounded: ≤ 1 interval when connected) |
| forged `om2m/cluster/brokers` | only hosts under `CLUSTER_ALLOW_PREFIX` accepted | worst case: a sensor tries a wrong host on the subnet, gets no acks, fails over |

**Residual risks, stated plainly.**
- **The brokers are anonymous.** Anyone on the subnet can publish a fake reading or a
  fake presence, exactly as in v1. This is the existing trust boundary of the testbed's
  MQTT layer, and the trust engine's observations are signed for that reason. Authenticating sensors needs
  per-device MQTT credentials or TLS client certificates. The firmware already supports
  `MQTT_USER`/`MQTT_PASS`.
- **History is not migrated after a parent change.** Each parent holds the readings
  written while it was parent. Readings are never duplicated within a tree, and the
  union is complete (test C8).

## 6. What changed from Hamza's v1, file by file

| v1 | v2 |
|---|---|
| `MQTT_HOST` single broker | `CLUSTER_SEEDS` + `HOME_NODE` + learned membership + `cluster.h` |
| `boot` id + `seq` (per boot) | NVS `epoch` + `seq`; `boot` kept for diagnostics |
| per-connection presence, unordered | session-ordered presence and Last Will |
| no delivery feedback | per-reading acks, resend buffer, no-ack failover |
| `layout = flat` container under the CSEBase, `acp_admin` | DAC-protected AE `/in-cse/C<device>` + `data`/`status` |
| writes to the local CSE | writes to the chain-named parent (or `target = local`) |
| `das/gated_read.sh`: NOTIFY the DAS | `das/protected_read.sh`: ordinary RETRIEVE through DAC |
| `das/protect_sensor.sh`: v7 ids, one token | v8 `env.v8.sh` ids, one READ token **per node** (the DAS signs as the parent, which can change) |
| `deploy_to_pis.sh`: `sshpass`, 3 nodes | SSH key auth, 5 nodes, checks DAC wiring and cross-node :8282 |
| `chain_sim.py`: v7 | v8: DENY found by simulation, not paid (F3) |
| tests: 17 + 17 | see §7 |

## 7. Verification (offline: `./run_all_tests.sh`, log in `evidence/offline_test_run.txt`)

| Group | Result |
|---|---|
| `cluster.h` against `selector_vectors.txt` | 27/27 |
| `esp32_sim.Selector` against the same vectors | 27/27 |
| firmware host build (the real `.ino`, virtual time, simulated 5-node cluster) | 10/10 |
| bridge unit tests | 12/12 |
| single-node e2e: Hamza's 17 scenarios adapted, plus 3 v2 checks | 20/20 |
| 5-node cluster e2e (real Mosquitto ×5, real bridge ×5) | 26/26, three consecutive runs |
| dashboard simulator self-test (5 nodes) | 19/19 |

**Mutation checks** (`evidence/mutation_checks.txt`). Each guard was broken in turn, and
the test aimed at it failed. All 7 were caught:
- the resend buffer;
- the hysteresis window;
- the no-ack failover;
- the learned-host prefix;
- the session order (stale Last Will);
- the deterministic reading names (CSE 409);
- fail-closed on missing DAC wiring.

**Bugs the tests found and fixed while building v2:**
- **Acks.** An ack carried only the highest stored seq, so a gap below it (reading 0,
  taken before the first connection) was never re-sent. Acks are now per reading.
- **No-ack timer.** It compared against the loop's start time, but a DHT retry
  (`delay(1100)`) runs before the publish timestamp is taken, so the unsigned
  difference wrapped and fired at once. This would have happened on hardware too.
- **Return home.** A sensor failed over for "no acks" went straight back, because the
  1 s base backoff had expired during that same DHT retry. `penalize()` fixes this and
  gates the return home.

## 8. To confirm on the real testbed **[live]**

1. **OM2M rejects a duplicate contentInstance name with 409.** `smoke_test.sh` (step 1,
   `--check`) prints which way it went. If not, exactly-once relies on the bridge
   cache plus acks alone, which is still single-bridge exact.
2. **`PUT` of an AE's `lbl` succeeds.** The C2 finding saw an AE PUT of `acpi` return
   200 but be ignored, so the stats `latest_label` and `latest_label_failed` should be
   checked.
3. **CONFIRMED 2026-11-10 (read-only, `evidence/live_check_2026-11-10.txt`):** every
   node reaches every other node's `:8282` (20/20 pairs HTTP 200, rpi4/rpi5
   included), so writing to the parent works on the real network.
4. **CONFIRMED 2026-11-10:** `acp_sui_dac`, `sui-dac` and `sui-das` return 200 on all
   five nodes, so the bridge's fail-closed check passes everywhere.
5. **A reader's RETRIEVE on the parent is granted on-chain** only after
   `das/protect_sensor.sh` has given that reader a mapping and a token on every node,
   and OM2M has been recreated through `scripts/v8/04_cutover.sh`.
6. **`flexContainer`** (OM2M `FlexContainerController` does call `checkPermissions`)
   would let the data itself be DAS-protected, not just the AE. This needs a probe on
   real OM2M before adopting it.
