# SY5: Replay of a Signed Observation Does Not Double-Count — Fix and Evidence

Status: VERIFIED on the live testnet cluster, 2026-06-23.

## The gap (before)
Gossip observations are signed (GO1/GO5) but carried no replay guard at ingest.
TrustGossip.latest keeps only the newest per (observer,target), so replaying the
CURRENT latest is idempotent (last-write-wins) — but an OUT-OF-ORDER replay of an
older, still-validly-signed observation within the freshness window would be
accepted and could override a newer stored observation. Mostly-safe but not
explicitly replay-hardened.

## The fix (Java, gossip ingest — no contract change)
TrustGossip ingest now enforces a monotonic producedAtMs per (observer,target):
before storing, it compares the incoming observation's producedAtMs against the
stored one and REJECTS any whose timestamp is not strictly newer
(obs.producedAtMs <= prev.producedAtMs -> drop + warn). This also rejects exact
duplicate replays. Commit: SY5 on MouazKass/sui-om2m main.

## Test (matches the invariant's test)
Replay an older signed observation within the window; assert it does not
override a newer one.
- Captured a live signed observation from the bus: observer rpi3 (0x27dac...),
  target rpi2 (0x4be6...), producedAtMs=1782242297601.
- After newer observations were stored, re-published the captured (older)
  payload verbatim via mosquitto_pub. The signature is genuine, so it passes
  GO5 signature verification.
- Result: both receiving nodes (rpi1, rpi2) logged:
    [trust] SY5 replay rejected: stale/duplicate obs from 0x27dac... about
    0x4be6... (producedAtMs 1782242297601 <= stored 1782242360602)
  The replayed older observation was rejected; the newer stored value was not
  overridden.
Evidence: sy5-replay-rejected-20260623-*.log
