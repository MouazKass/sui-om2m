# ESP32 sensing layer (cluster edition)

ESP32 sensors feed the Sui-OM2M testbed. A sensor attaches to **any** Pi of the
cluster and moves to another one when its Pi, its broker or its bridge fails. Its
readings are stored **once**, on the cluster's current parent, as an `<AE>` that an
ordinary oneM2M RETRIEVE can only read after an on-chain decision by the Sui DAS.

The design, the failure modes and the verification are in `DESIGN.md`; credits are
in `AUTHORS.md`.

```
esp32/
  firmware/esp32_sensor_node/   esp32_sensor_node.ino, config.h, cluster.h (broker selection)
  pi/                           om2m_ipe_bridge.py (runs on every Pi), bridge.conf.example,
                                members.conf.example, install.sh, systemd/, smoke_test.sh
  das/                          protect_sensor.sh (council votes), protected_read.sh (on the parent)
  sim/                          esp32_sim.py, mock_cse.py, chain_sim.py, mock_sui_gql.py,
                                tcp_proxy.py, run_e2e.py, run_cluster_e2e.py, firmware_hostcheck/
  tests/                        test_selector.py, test_bridge_unit.py
  simulate.py                   the whole 5-node testbed + dashboard on one laptop
  deploy_to_pis.sh              check | members | install <rpiN|all> | status
  run_all_tests.sh              every offline check
  evidence/                     test runs, mutation checks, live logs
```

## 1. Offline: no hardware, no Pi, no wallet

On Linux or WSL you need `g++`, `mosquitto`, and Python 3 with `paho-mqtt`,
`requests` and `flask` (`sudo apt install mosquitto python3-paho-mqtt
python3-requests python3-flask g++`). Then:

```
./run_all_tests.sh              # selector vectors (C++ + Python), firmware host build,
                                # bridge unit tests, single-node e2e, 5-node cluster e2e,
                                # dashboard self-test  -> "ALL TEST GROUPS PASSED"
python3 simulate.py             # dashboard at http://127.0.0.1:8000
```

Without installing anything on a host, run the same suite in a throwaway
container (default: on rpi1 over ssh; `E2E_HOST=local` for this machine's docker):

```
esp32/sim/run_e2e_in_docker.sh  # debian + g++ + mosquitto + pinned paho/requests/flask,
                                # --network none, sources mounted read-only;
                                # container, image and temp dir removed afterwards
```

The sims bind only 127.0.0.1 ports inside the container, so they cannot touch the
live brokers. Last run: `evidence/e2e_in_docker_2026-11-11.txt`.

From the dashboard you can:
- power a sensor off;
- inject bad payloads, or replay a reading into another node's broker;
- **kill a node's broker** (the sensor fails over) or **make another node the parent**
  (writes follow);
- restart or stop OM2M (tree wipe or outage);
- **protect** a sensor on-chain, then read it through the DAS;
- drop the parent's trust.

## 2. Hardware day: flashing an ESP32

1. In the Arduino IDE, install the `esp32` board package and these libraries:
   **PubSubClient**, **DHT sensor library** and Adafruit Unified Sensor. Choose the
   board "ESP32 Dev Module".
2. Edit `firmware/esp32_sensor_node/config.h`:
   - `WIFI_SSID` and `WIFI_PASS`. The network must be 2.4 GHz, without
     WPA2-Enterprise or a captive portal.
   - `DEVICE_ID`: unique, lowercase, digits and `-` only.
   - `HOME_NODE`: the preferred Pi, e.g. `rpi2`.

   Leave `CLUSTER_SEEDS` listing all five Pis. Later nodes are learned at run time.
3. Wiring: DHT11 VCC→3.3 V, DATA→GPIO4, GND→GND. The LDR divider goes into GPIO34
   (LDR to 3.3 V, 10 kΩ to GND).
4. Upload. Hold BOOT if it hangs on "Connecting…". In the Serial Monitor at 115200
   you should see:
   - `[wifi] connected`;
   - `[mqtt] connected to rpi2 … session <epoch>.1`;
   - `[pub] ok seq=…`.

   Unplug its home Pi's network and you should see `[mqtt] lost rpi2, failing over`
   and then `connected to rpi3`.

## 3. Deploying the bridge on the Pis

Run this from the laptop, on the VPN. It uses SSH key auth only
(`~/.ssh/id_ed25519_suiom2m`).

```
./deploy_to_pis.sh check        # SSH, OM2M, acp_sui_dac / sui-dac / sui-das, broker, deps,
                                # and the node-to-node :8282 matrix (writes go to the parent)
./deploy_to_pis.sh members      # writes pi/members.conf from deploy/inventory.tsv
./deploy_to_pis.sh install rpi2 # one node first: install + smoke test
./deploy_to_pis.sh install all
./deploy_to_pis.sh status
```

`install` never touches the OM2M container, `sui.properties`, the mappings or the
broker mesh. It reads the cluster id and type-origin package id from the node's own
`~/sui-runtime-config/sui.properties` and fills them into
`/etc/om2m-ipe-bridge/bridge.conf`. If that node has no cluster id yet, the bridge runs
with `target = local`.

Nodes come from `deploy/inventory.tsv`, the testbed's single node list
(`scripts/lib/inventory.sh`). `check`, `install all` and `status` cover the `active`
nodes; `members` lists every node, pending ones included, so sensors can use a node as
soon as it is active.

**Adding a node later:** onboard it (the inventory status becomes `active`), then run
`./deploy_to_pis.sh members` and `install all`. Every bridge re-reads `members.conf`
and republishes it, so sensors learn the new node without a reflash.

## 4. Putting a sensor behind the chain

1. From Git Bash on the laptop (VPN up), repo root:
   ```
   esp32/das/protect_sensor.sh esp32-dht-01 Cesp32-reader-01 rpi2   # token for rpi2 only
   esp32/das/protect_sensor.sh esp32-dht-01 Cesp32-reader-01        # a token for every active node
   ```
   Since v9 the 3-of-5 council holds PolicyAdminCap and IssuerCap, so the script
   does not use any publisher cap. Each write is a council vote through
   `scripts/v9/council.sh`: proposed by the first of `SIGNERS` (default `rpi1 rpi3 rpi4`),
   approved by the other two, then executed. Each step is signed on that Pi with its own key.
   Votes: one `policy-set` (READ on `/in-cse/C<device>`), then one `token-mint` per
   token owner. The DAS signs as its own node, so only a node that holds a token can
   serve a protected read. The two mapping lines per owner are written to
   `deploy/v9/mappings/<node>.properties`, which is committed.
2. `scripts/v8/03_gen_config.sh` appends that file to the node's generated
   `sui.mappings.properties`. Its self-check verifies the `\:\:` escaping and that
   the `addr.` line is the node's own address. Then run
   `ONLY=rpi2 scripts/v8/04_cutover.sh config` and `... redeploy`. Mappings are read
   only at plugin start, and the bridge re-provisions the AE after the wipe.
   Today every active node (rpi1–rpi5) holds its own READ token for `esp32-dht-01`
   (council proposals 6–10), so a protected read keeps working whichever node is
   parent; verified live across an rpi2 → rpi3 → rpi2 handover on 2026-11-11
   (`evidence/protected_read_failover_2026-11-11.txt`). A node added later needs one
   more `token-mint` vote (`SKIP_POLICY=1 … protect_sensor.sh <device> <reader> <node>`).
3. On the parent: `esp32/das/protected_read.sh esp32-dht-01 Cesp32-reader-01`. Expect:
   - RETRIEVE → HTTP 200, the `latest=` reading and a `Sui GRANT` log line;
   - DELETE → 403, with a `Sui DENY` found by simulation and no transaction (F3);
   - the `data` container → 403 with no Sui line (containers are never DAS-checked).

## 5. Topics and payloads

| Topic | Direction | Payload |
|---|---|---|
| `sensors/<id>/telemetry` | sensor → bridge | `{"v":2,"id","epoch","boot","seq","ts","up_ms","rssi","via",<measurements>}` |
| `sensors/<id>/status` | sensor → bridge, retained | `{"state":"online","session":"<epoch>.<n>",…}`; Last Will `{"state":"offline","session":…}`; empty = cleared |
| `sensors/<id>/ack` | bridge → sensor | `{"epoch","seq","node"}`, one per stored reading |
| `om2m/cluster/brokers` | bridge → sensors, retained | `v1;<ts>;rpi1=10.25.96.200:1883:1,…` |
| `om2m/cluster/members` | bridge → tools, retained | JSON: members, liveness, parent |

`sensors/#` and `om2m/cluster/#` are deliberately **not** bridged by the broker mesh.
Each bridge serves the sensors on its own broker and announces membership there. v1
payloads (`"v":1`, boot id, no epoch) are still accepted.

## 6. Notes for the infrastructure owner

- **Never DELETE a DAS-wired AE directly.** OM2M 1.x (EclipseLink) leaves a deleted
  AE in the cached `sui-dac` list. After that, every NEW AE created with that `daci`
  fails with HTTP 500 (`FK_AE_DAC_JOIN_AE_ID`) until `om2m-active` restarts. This was
  seen live on 2026-11-10: the first `install all` probes poisoned the parent, and the
  smoke tests on rpi1/3/4/5 failed. Unlink first, then delete:
  `PUT {"m2m:ae":{"daci":[]}}`, then `DELETE`. The bridge's `--check` now does this
  (`CSE.delete_ae`).
- The bridge needs `provision-das.sh` Part B (`acp_sui_dac`, `sui-dac`) on **every**
  node. It fails closed and buffers without it.
- The bridge writes to the parent's PoA, so every node must reach every other node's
  `:8282`. `deploy_to_pis.sh check` shows the matrix.
- **Optional plugin hook (not required):** a local, read-only HTTP endpoint on each node
  serving the plugin's cached `current_parent` + PoA. Today the bridge reads the same
  two fields from Sui GraphQL itself, so the endpoint would only remove that
  dependency.
- When `sui.package.id` moves to v9, the bridge keeps working, because it uses
  `sui.package.original.id` (the type origin) for `ParentPoaKey`. On v9 it also honours
  `ParentPoaOwnerKey`.
