# Zero-Trust Hardening — Test Evidence (2026-06-02)

Package v4: 0x7208dd4bcd25a69007317185524538cc44f00909a9bce8a9ea0b0976a30ad099

## Test 1 — On-chain self-scoring guard (AdminCap hardening)
rpi1 attempts decrease_guarded targeting its own address (sender==target):
  RESULT: aborted in trust::decrease_guarded at instruction 13 with code 4 (E_SELF_SCORING)
  tx: 81epA6NWUvY6GHrzbtWc9o6aozLhw2Vms3iPLrvrz57S
  => Self-scoring blocked on-chain. PASS.

## Test 2 — Guarded path works for legitimate peer write (sender != target)
rpi1 decreases rpi2:
  RESULT: Status Success
  tx: BEvHXbbUXLioFyArtciL6AxQkQaTRDgMvAZWSX4RPJvv
  => Peer-attestation path intact. Guard is precise. PASS.

## Test 3 — MQTT broker mesh (SPOF removed)
Killed rpi1's broker; gossip continued via rpi2/rpi3 bridge.
  rpi2 sub count after kill: 128104  rpi3: 128006  (baseline ~66206)
  => Cluster gossip survives loss of any one broker. PASS.
  Note: full mesh roughly doubles traffic (loop relay); idempotent under signing.

## Test 4 — Self-observation publishing
Nodes now publish observations where observer==target (peer corroboration);
self still excluded from local scoring.
  Observed: v1|0xef9c...|0xef9c... self-obs messages on gossip topic. PASS.

## Caveats documented for paper
- Fail-closed cold-start (#2) verified by code path, not forced-failure live test.
- Remaining threat-model gaps (out of scope): collusion in 3-node majority
  attestation, advisory-only gate enforcement, key compromise.
