# ESP cluster VIP: one address for every sensor

The ESP32 sensors connect to **one** address, `192.168.1.250:1883`, on the
router's Wi-Fi (sensors on `ESB1032-2.4`; the Pis on `ESB1032-5`, the same
router and LAN, `192.168.1.0/24`). keepalived (VRRP) keeps that address on
exactly one Pi:

* **on the current on-chain parent** (the most trusted node, which stores the
  readings), and it follows the parent when the role changes;
* **only while that Pi can serve sensors**: Wi-Fi up, MQTT broker answering,
  ESP bridge running. If the parent fails one of these, the highest-priority
  healthy non-parent holds the address until the parent is healthy again.

| File | Installed as | Role |
|---|---|---|
| `keepalived.conf.tmpl` | `/etc/keepalived/keepalived.conf` | one VRRP instance; unicast adverts over **eth0**, the address on **wlan0** |
| `esp_ready.sh` | `/etc/keepalived/esp_ready.sh` | hard check: wlan0 has an address, `127.0.0.1:1883` accepts, `om2m-ipe-bridge` active. Failure → FAULT, the node gives up the address |
| `is_parent.sh` | `/etc/keepalived/is_parent.sh` | weight +100 while this node is the parent. Reads `/var/lib/om2m-ipe-bridge/parent.json`, which the ESP bridge rewrites after each chain poll (`parent_poll_s`, 10 s). No extra chain query, no chain write. Stale for 30 s → not parent |
| `install_vip.sh` | — | renders the config per node from `deploy/inventory.tsv` (base priorities 150, 140, … in inventory order; unicast peers = the other active nodes), tests it with `keepalived -t`, (re)starts keepalived, prints the holder |

```bash
deploy/vip/install_vip.sh               # all active nodes (re-run after adding a node)
ONLY=rpi5 deploy/vip/install_vip.sh     # one node
```

## Design choices

* **Adverts over the wired LAN, address on Wi-Fi.** The control traffic uses
  the stable eth0 link and is not exposed to Wi-Fi multicast filtering; the
  address the sensors use lives on wlan0. `track_interface wlan0` gives up the
  address if a Pi's Wi-Fi drops.
* **Preemption with `preempt_delay 5`.** The address must move to a new parent,
  so preemption is on; the delay damps flapping while the five bridges' chain
  polls catch up with a parent change.
* **Wi-Fi never routes.** Each Pi's Wi-Fi profile has `ipv4.never-default yes`
  and `ipv4.ignore-auto-dns yes`: the default route and DNS stay on eth0, so
  the chain, gossip, failover and SSH are unaffected.

## Trade-off: when the parent crashes

The address follows the **on-chain** parent. If the parent Pi dies outright,
`esp_ready` and VRRP move the address to the best healthy non-parent within a
few seconds, and the sensors reconnect there; that bridge stores their
readings the same way any bridge does (replicated to every node and acked on a
quorum, `esp32/DESIGN.md` §11), so no parent is needed to accept them. Readings
no bridge has acknowledged stay in each sensor's buffer and are re-sent. Once
the cluster elects a new parent (failover lease) and that node's bridge sees
it on its next chain poll, the address moves there: one more reconnect.

## Measured (live, 16 Nov 2026, `esp32/sim/live_vip.sh`)

| Event | VIP moved after |
|---|---|
| parent's ESP bridge stopped | 3 s (to the best healthy non-parent) |
| that bridge started again | 14 s (back to the parent) |
| parent role moved on-chain rpi2 → rpi3 | 23 s |
| and back rpi3 → rpi2 | 17 s |

135 readings, all on all five CSEs, none lost; never two holders. Details:
`ROLLOUT_V9.md`, "ESP cluster VIP".

## Security note

The brokers are anonymous and the address is announced with plain ARP, so a
device on the Wi-Fi could answer for `192.168.1.250`. That is not what keeps
the data safe: a reading is accepted only if the device signed it with its
registered on-chain key, and a sensor drops a reading from its buffer only on
an acknowledgement signed by a pinned bridge key (`esp32/README.md` §7). An
impostor can delay readings, not forge or swallow them.

**Router:** exclude `192.168.1.250` from the router's DHCP pool (or reserve it),
so the router never hands it to another client.
