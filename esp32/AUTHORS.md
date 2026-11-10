# Authors

**Hamza AlCharif** designed and wrote the original ESP32 sensing layer (handover
`esp32-om2m-bridge`, v1). Its core is carried forward unchanged in spirit:
- the sensor firmware and its payload schema;
- the MQTT→oneM2M interworking proxy, including its validation, range checks,
  dedupe, buffering through OM2M outages, re-provisioning after a wipe, and the
  "ACP from birth" rule;
- the OM2M emulator, the chain simulator, the ESP32 simulator, the firmware host
  build, the single-node end-to-end suite and the dashboard.

His `REVIEW.md` findings B1–B6 were confirmed and addressed in the v8 batch:
- B1, the "read" mislabelling, was fixed in the proof scripts;
- B2 and B3, the interworking-proxy and mesh wording, were fixed in the paper;
- B4: the paper now describes the DAC path, not "interception";
- B5: the version drift was fixed;
- B6: the `\:\:` escaping is documented.

**Mouaz Kassouma** (with Claude Code), 2026-11: v2, the cluster edition.
- **Firmware:** cluster-wide broker selection (`cluster.h`), learned membership, NVS
  epoch numbering, per-reading acks with a resend buffer, session-ordered presence, and
  no-ack failover.
- **Bridge:** parent-targeted writes read from the chain, the DAC-protected AE layout,
  CSE-side exactly-once storage, session-aware status, and the membership publisher.
- **Tests and tools:** the 5-node simulations and tests, plus the v8/v9-correct DAS
  scripts.
