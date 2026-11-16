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
| forged reading (attacker's own key, or no key) | `[identity] mode = require`: signature + on-chain registry lookup | rejected, never acked, never stored (§9) |
| device revoked by the council | registry lookup (cached ≤ 60 s) | its readings are rejected; the board buffers them |
| forged ack on `sensors/<id>/ack` (unsigned, foreign key, other device, altered) | v2.2: the board accepts only acks signed by a pinned bridge ack key, for its own id and epoch | ignored: the reading stays in the resend buffer, and the no-ack failover still fires (§10) |
| replay of an old genuine reading after a bridge restart, or to another bridge | v2.2: durable replay floor (`replay.json`) raised from the parent CSE | rejected (`stale_epoch` / `stale_seq`), never stored (§10) |
| forged `om2m/cluster/brokers` | only hosts under `CLUSTER_ALLOW_PREFIX` accepted | worst case: a sensor tries a wrong host on the subnet, gets no acks, fails over |

**Residual risks, stated plainly.**
- **The brokers are anonymous, but readings are not (v2.1).** Anyone on the subnet can
  still *publish*, but a reading or presence message is stored only if it is signed by
  a device key registered on-chain for that device (§9), and since v2.2 a board
  trusts only acks signed by a pinned bridge key (§10). What a publisher on the
  broker can still do is flood it: availability, not integrity. Broker ACLs
  (`MQTT_USER`/`MQTT_PASS` are supported by the firmware) would bound that.
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
| no device authentication | v2.1: per-device Ed25519 key, signed messages, on-chain registration by council vote (§9) |

## 7. Verification (offline: `./run_all_tests.sh`, log in `evidence/offline_test_run.txt`)

| Group | Result |
|---|---|
| `cluster.h` against `selector_vectors.txt` | 27/27 |
| `esp32_sim.Selector` against the same vectors | 27/27 |
| firmware host build (the real `.ino`, virtual time, simulated 5-node cluster) | 13/13 (v2.1 adds: signed telemetry, signed Last Will, key kept across power cycle) |
| bridge unit tests | 12/12 |
| device identity unit tests (`tests/test_identity.py`: RFC 8032 vector, Sui address vs a live key, format, registry, bridge decisions) | 17/17 |
| firmware signatures (C++/libsodium) verified by the bridge's Python verifier | 3/3 (92 telemetry + 5 status) |
| single-node e2e: Hamza's 17 scenarios adapted, plus 3 v2 checks | 20/20 |
| 5-node cluster e2e (real Mosquitto ×5, real bridge ×5) | 31/31 (v2.1, identity required; C10 forged/unsigned/tampered/revoked) |
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

## 9. Per-device identity (v2.1)

**Problem.** In v2 a sensor was just an MQTT topic. Anyone on the subnet could
publish `sensors/esp32-dht-01/telemetry`, and the bridge would store it as that
device's reading on the parent. A DAS-protected read then served forged data
behind a genuine on-chain GRANT.

**Design.** Each device holds its own Ed25519 key, generated on the device and kept
in NVS (`firmware/.../device_key.h`, libsodium). Its identity is the key's Sui
address, `blake2b-256(0x00 ‖ pk)`. The council registers it in the existing
identity registry as `ROLE_AE` with `cse_id` = the device id, using the existing
`id-register` action. Revocation is `id-deregister`. Nothing in Move changed. The
roles already keep a device key out of every middleware path on-chain:
- `failover::claim_parent` requires IN/MN;
- `quorum::assert_eligible` requires IN/MN;
- `evaluator::log_deny_batch` requires IN/MN.

The plugin's B10 gossip membership was the one place that only asked
`is_registered`. It now also reads `role_of` and admits IN/MN only
(`IdentityRegistryMembers`, `IdentityRoleMembershipTest`). That plugin change was
deployed to all five nodes **before** the first device was registered.

**Signature format** (`pi/esp_identity.py`). `"pk"` is added anywhere in the JSON
object, and `"sig"` is added as the **last** field:

```
sig = Ed25519(sk, "om2m-esp32-sig-v1 " || body)
```

Here `body` is the exact bytes of the message without `,"sig":"…"`. The board signs
the bytes it already built, so no canonical JSON is needed. The verifier
re-parses the signed body and requires it to equal the parsed message minus
`sig`, so no field outside the signature can reach storage. The Last Will is
signed at connect time, since its content (session id) is fixed then.

**Bridge check** (`[identity] mode = require`):

1. Verify the signature, then derive the address from the key.
2. Look the address up in `Registry.nodes` over GraphQL (a read; no gas, no signing).
   It must be role 3 and `cse_id` = the device id in the topic.
3. Reject replays:
   - an epoch older than one already authenticated;
   - a device timestamp older than `replay_window_s`.
4. Store `pk`, `sig` and `signer`, and label the AE `signer/<address>`.

The registry answer is cached, with a positive TTL of 60 s (the bound on revocation
latency) and a negative TTL of 15 s. If the chain cannot be read, a positive answer
up to 300 s old is reused; with nothing cached the bridge rejects (fail closed).

**Why not more.**
- The device does not sign Sui transactions. It has no gas, and the DAS still
  authorises *readers* through their node's token. The identity authenticates and
  attributes the *data*.
- Per-device DAS attribution was added in v10 (2026-11-11, `V10_DESIGN.md`): the
  sensor resource's policy is bound to the device's address, and a read is granted
  only while the device is registered.

## 10. Signed acknowledgements and the durable replay floor (v2.2)

**Problem 1: acks were unsigned.** A board drops a reading from its resend buffer
when an ack for (epoch, seq) arrives, and treats any ack as proof that a bridge is
alive behind its broker. Anyone on the broker could therefore make a board discard
readings no bridge had stored, and hide a dead bridge from the no-ack failover.

**Design.** Each bridge has its own Ed25519 **ack key**, generated on its Pi by
`install.sh` as the dedicated service user `om2m-ipe`
(`/var/lib/om2m-ipe-bridge/ack.key`, 0600, systemd `StateDirectory`, never copied).
The ack names the device and is signed under its own domain tag:

```
ack = {"id":<device>,"seq":S,"node":<label>,"epoch":E,"ts":T,"apk":<pk hex>,"sig":<hex>}
sig = Ed25519(ack key, "om2m-esp32-ack-v1\0" || <ack without the sig field>)
```

The board pins the bridges' **public** ack keys at flash time
(`firmware/gen_ack_keys.sh`: `deploy/v9/ack_keys/<node>.pub` → `ack_keys.h`,
`ACK_TRUSTED_KEYS`) and accepts an ack only if `apk` is pinned, the signature
verifies (libsodium `crypto_sign_verify_detached`), `id` is its own device id and
`epoch` its current epoch. It parses only the signed body. The distinct domain tag
means a device signature can never pass as an ack, or an ack as a reading.

*Why pinned keys, not the on-chain registry.* The board cannot read the chain
(no light client, no gas), and a key learned from the broker at run time would
be exactly what an attacker on the broker could supply. A pinned list is the one
anchor the attacker cannot touch. The cost: a new node's ack key must be added to
the boards (`gen_ack_keys.sh`, reflash). Readings sent through a node whose key is
not yet pinned are simply re-sent elsewhere (no-ack failover), never lost. A
replayed old ack is harmless: it confirms a (device, epoch, seq) that bridge did
store.

**Problem 2: the replay floor lived in memory.** "An older epoch than one already
authenticated" was a per-process value, so a restarted bridge, or a different
bridge, accepted a genuine old-epoch reading once (within the 1 h timestamp window).

**Design.** Per device the bridge keeps (newest authenticated epoch, highest seq in
it) in `state_dir/replay.json`: temp file, `fsync`, `rename`, `fsync` of the
directory, so a crash leaves the old or the new file. An epoch increase is written
at once; seq progress at most once a second (a crash can lose < 1 s of it, which the
CSE's `e<epoch>-s<seq>` name collision covers). On first contact with a device, and
every `floor_refresh_s` (60 s), the floor is also **raised from the newest reading on
the parent CSE**, the one store every bridge writes to. That makes the floor shared
across bridges without any bridge-to-bridge protocol: a device that failed over from
another bridge, or a replay sent to a bridge that never saw the device, meets the
same floor. Rejected:

- an epoch below the floor (`auth:stale_epoch`);
- in the floor's epoch, a seq more than `seq_window` (256) below the highest
  (`auth:stale_seq`). The board can only resend from its 64-slot buffer, so nothing
  genuine is that old; 256 < `mni` (1000), so everything inside the window is still on
  the CSE and a second copy is refused there (409).

Only authenticated messages move the floor, so a forger cannot push it forward to
lock a device out. If the CSE cannot be read, the local floor is used and the read is
retried after 5 s. A corrupt `replay.json` is moved aside (`.corrupt`) and the CSE
floor still applies.

**Verification.** `tests/test_ack_replay.py` (16 unit tests: ack format and
forgeries, domain separation, key file, key made 0600 in the state dir, floor across
a restart, the regression without a state dir, CSE floor for a fresh bridge, cache
and refresh, CSE down, seq window, corrupt file, unauthenticated messages never move
the floor); the firmware host check (forged acks during the silent-bridge window are
all ignored, the failover still happens, nothing lost); cluster e2e C9 (forged acks
while a bridge is down) and C11 (old-epoch replay after a bridge restart and to a
bridge with wiped state); and the live run in `ROLLOUT_V9.md`.

## 11. Losing the parent costs zero readings (v2.3)

Before v2.3 a reading had one copy, on the parent's CSE, and OM2M kept it in memory:
`dbReset=true` wiped the H2 database at every start and the database lived in the
container layer. A parent crash, or even a planned redeploy, lost every reading
stored on it (seen live on 2026-11-11: about 45 test readings). v2.3 closes this with
three changes that only work together.

**1. Durable CSEs.** Every node's OM2M keeps its resource DB on disk:
`dbReset=false`, `WRITE_DELAY=0` (H2's default 500 ms write delay would lose an
acknowledged commit on a kill), and the `database/` directory is a host volume
(`/home/user/sui-runtime-config/om2m-db`), so a container restart, recreate or
redeploy keeps it. Set in the image build and the container definition in
`scripts/v8/04_cutover.sh`; DAS provisioning was already idempotent (201/409).

**2. Replication and the quorum ack** (`pi/replicator.py`, `[replication] mode = all`).
Each authenticated reading is written to the CSE of **every** member (same path,
same `e<epoch>-s<seq>` name, the same signed content), in parallel. A 201 or a 409
(already there) counts as held. The signed ack goes back to the board **only once a
quorum holds it** (default: a majority of `members_file`, 3 of 5). Below quorum: no
ack, the board re-sends, and the retry's 409s count. So an acknowledged reading is on
at least 3 disks and survives the loss of any 2 nodes, the parent included.

- A member that fails is skipped for a doubling back-off (5 s to 60 s), so a dead node
  cannot slow every ack down to the HTTP timeout; one write round is bounded by
  `write_timeout_s` (3 s).
- What a member missed goes into a per-member backlog, drained when it is reachable
  (`backfill`).
- **Reconcile**: the leader (the parent's bridge, or the first live member while the
  parent is down) compares the reading names on every live CSE (OM2M discovery,
  `fu=1&ty=4`) every 5 min and whenever a member comes back, and copies the gaps
  byte for byte. On a member whose container is full (`mni`), readings older than its
  oldest are retention-evicted and are not re-added; on any other member (it was down,
  or lost its disk) everything it lacks is a gap.
- The replay floor (§10) is raised from the newest reading on any live replica.
- A re-sent reading that the floor calls stale but that is already stored somewhere is
  **acked**, never stored again, so a board's strictly ordered backlog cannot wedge on it.
  One that is stale and stored **nowhere** (an NVS rollback, two boards sharing a key)
  is still rejected, but the signed ack is marked `"stale": true` so the board drops it
  instead of re-sending it for ever (found live, 2026-11-16).
- Status (online/offline) is presence, not a reading: it is written to every live
  member, best effort, and never holds up the readings queued behind it. (Found live:
  bound to the parent only, a status item blocked every reading while the parent's
  CSE was stopped.)
- Protected reads: every replica carries the same AE (`/in-cse/C<device>`, `acp_sui_dac`,
  `sui-dac`), so a RETRIEVE on any CSE is decided by that node's Sui DAS, exactly as on
  the parent (and v10's device binding applies on every node).

**3. A durable resend buffer on the board** (`firmware/.../flash_buffer.h`, fw 2.3).
Every reading is written to flash (LittleFS on the `spiffs` partition) before it is
sent, and leaves the buffer only on a signed ack. 1,440 slots = 2 h at 5 s; it survives
a reboot or brown-out.

- One sender, oldest first, at most 16 unacked in flight, re-sent after 15 s.
- **Epoch barrier**: a new power-up's readings are not sent while the previous epoch
  still has unacked ones, because the bridges' floor rejects an older epoch once it has
  seen a newer one. 16 in flight is far below `seq_window` (256), so in-epoch order
  never trips the floor either.
- Each slot carries a CRC, so a slot torn by a power cut reads as empty, not garbage.
  Ack state is keyed by (epoch, seq) per slot and written in batches every 30 s: a
  reused slot can never look acked; after a reboot a few acked readings may be sent
  again and are dropped as duplicates.
- Wear: one ~660-byte slot write per reading, wear-levelled over ~350 blocks: about 50
  erases per block per day at 5 s, years on 100k-cycle flash.
- The bridges' `replay_window_s` is raised from 1 h to 12 h so a drained backlog is
  not rejected as old.

**What is still lost, and only then:** a reading the board took but could not store
(flash mount failure, logged at boot), a buffer overflow (more than 2 h with no quorum:
the oldest unacked slot is reused, logged), or three or more nodes losing their disks at
once.

**The parent's lease is unchanged** (anchor every 600 s, 1,200 s lease): with the
quorum ack, readings never wait for a new parent, so a takeover only delays the
parent's own duties. A 120 s anchor would cut the expected takeover from ~15 min to
~3 min for 5x the renewal gas (720/day, ~0.72 SUI) and would let a short chain/RPC
outage cost a healthy parent its role. `failover.lease.anchor.period.ms` stays
configurable.

**Verification.** `tests/test_replication.py` (12: quorum default, all-up, parent plus
one down still acks, no quorum then recovery via 409s, circuit breaker, backfill,
leader choice, gap vs evicted history, wiped replica, the bridge running as `__main__`,
stale-but-stored ack); `sim/firmware_hostcheck/fb_test.cpp` (15: window, order, reboot,
epoch barrier, retry timing, overflow, torn slot, reused slot, mount failure); the
firmware host check with the flash buffer on; `sim/run_replication_e2e.py` (R0 to R4:
replication, the parent killed mid-stream, no quorum plus a power cut, an empty node
caught up by reconcile, exactly once and complete); and the live run in `ROLLOUT_V9.md`.

## 12. One cluster address for the sensors (VIP, 16 Nov 2026)

**Problem.** Each board carried a list of the five Pis' wired addresses
(`10.25.96.x`), which a board on the router's Wi-Fi (`192.168.1.0/24`) cannot
reach, and every board had to know every node.

**Design.** All five Pis also join the router's Wi-Fi (ESB1032-5; the boards use
ESB1032-2.4, same router and LAN), with `ipv4.never-default` so routing stays on
eth0. keepalived (VRRP, `deploy/vip/`) holds **one** address, `192.168.1.250`,
on exactly one Pi:

* `is_parent` (weight +100) makes the current **on-chain parent** win. The bridge
  writes `/var/lib/om2m-ipe-bridge/parent.json` after each chain poll
  (`ParentResolver._write_status`), so the check costs no chain query.
* `esp_ready` (hard fault: wlan0, broker `:1883`, `om2m-ipe-bridge`) takes the
  address off a Pi that cannot serve sensors; the best healthy non-parent
  (base priority order) holds it until the parent is healthy again.
* Preemption with `preempt_delay 5` so the address follows a new parent without
  flapping; adverts unicast over eth0; `track_interface wlan0`.

The board is flashed with `config_local.h` (gitignored): one seed
`cluster=192.168.1.250:1883`, `CLUSTER_ALLOW_PREFIX "192.168.1.250"` so the
learned per-Pi addresses are ignored. `cluster.h` caps backoff at
`singleBackoffMaxMs` (2 s) when there is only one broker, penalties included, so
a board never shuts itself out of the only address it has. Shared vectors
(`sim/selector_vectors.txt`, single-broker section) hold firmware and simulator
to the same rule.

**Trade-off.** The address follows the *chain's* parent. If the parent Pi dies
outright, the address moves to a healthy non-parent within seconds; that bridge
writes to the cluster (replication, §11) and the address moves again once a new
parent is elected. Unacked readings stay in the board's buffer and are re-sent
after each move. Anyone on the Wi-Fi could answer ARP for the address; that can
delay readings but not forge or swallow them (signed readings, signed acks).

**Verification.** Offline: selector vectors 37/37 in both implementations, the
full suite (`evidence/e2e_vip_in_docker_2026-11-16.txt`). Live
(`sim/live_vip.sh`, `evidence/vip_live_2026-11-16.txt`): see `ROLLOUT_V9.md`
"ESP cluster VIP".

## 13. Signed over-the-air updates (v2.4, 16 Nov 2026)

**Problem.** Every firmware change needed a USB cable at each board, and nothing would
have stopped whoever could reach a board's network from pushing firmware to it.

**Design.**
- *Trust root:* a dedicated Ed25519 firmware-signing key, created in WSL on the publisher
  machine (`scripts/ota/keygen.sh`), never copied. Only its public key is pinned in the
  image (`fw_keys.h`, at most 4 keys; rotation = a release signed by the old key that pins
  the new one). The distribution path is untrusted.
- *Manifest* (`pi/ota_manifest.py` is the reference; `ota_core.h` mirrors it):
  `{"kind","version","target","size","sha256","path","fpk","ts"}` + `"sig"` last, signed
  under the domain tag `om2m-esp32-fw-v1\0`, each key exactly once (duplicate-key tricks are
  refused), path restricted to `/fw/<name>.bin`.
- *Distribution:* every Pi runs `pi/ota_server.py` (systemd `om2m-ota`: DynamicUser,
  read-only, no listing, GET/HEAD, `/fw/` only, Wi-Fi clients only). Boards fetch from the
  broker they are connected to, i.e. the cluster address 192.168.1.250, so whichever Pi
  holds it serves the image. Announce: retained `om2m/ota/manifest` on every broker;
  fallback poll every 6 h.
- *Install:* stream into the inactive slot (`Update.h`) while hashing (libsodium SHA-256);
  switch slots only if size and digest match (`Update.end` also validates the image).
  Buffers are heap-allocated only during a check or download (with static buffers the
  DRAM segment overflowed by 3.8 KB).
- *Anti-rollback:* NVS `ver` (installed) and `bad` (highest release that failed); a release
  must exceed both.
- *Rollback:* NVS `pend`/`tries`/`pslot`. A new image is on trial until it is connected and
  has a signed bridge ack (`ota::onHealthy`, which also calls
  `esp_ota_mark_app_valid_cancel_rollback`; `verifyRollbackLater()` returns true so the core
  does not confirm it early). After `OTA_MAX_TRIES` (3) boots without that, the board sets
  the other slot and restarts. If the bootloader already rolled back (the old slot is
  running), the board only records the failure and never switches onto the bad slot.
- *Identity guard:* `DEVICE_ID` is compiled in; the first-flashed ID is kept in NVS and a
  trial image with another ID is rejected at boot (a USB flash may change it).

**What it does not do.** No encryption of the image (it is public except the Wi-Fi
credentials, hence the Wi-Fi-only server and `--withdraw` deleting images); no secure boot
or flash encryption (one-way eFuse decisions for a deployment, see §9); one image per board
while `DEVICE_ID`/Wi-Fi are compile-time.

**Verification.** `sim/firmware_hostcheck/ota_test.cpp` (40 checks: signatures, domains,
duplicates, anti-rollback, target, size, path, streaming hash, the rollback state machine
across reboots, the identity guard), `tests/test_ota.py` (27: the Python reference, the
C++-signed manifests verified in Python, the server's path and client restrictions, the
full fetch-and-verify path). Real build: 1,118,202 bytes, 85 % of a 1.25 MB slot, 0
warnings. Live: `evidence/ota_live_2026-11-16.txt`.
