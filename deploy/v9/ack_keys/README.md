# Bridge ack public keys

One file per node, `<node>.pub`: the PUBLIC half of that bridge's Ed25519 ack
key, printed by `esp32/pi/install.sh` (the private key was generated on the Pi
as user `om2m-ipe` in `/var/lib/om2m-ipe-bridge/ack.key` and never left it).
Recorded 2026-11-11 from the v2.2 install on all five nodes.

`esp32/firmware/gen_ack_keys.sh` turns them into the firmware's
`ack_keys.h` (`ACK_TRUSTED_KEYS`) and `trusted.txt` (simulator `--ack-keys`).
Re-run it and reflash the boards when a node is added or a key changes.
