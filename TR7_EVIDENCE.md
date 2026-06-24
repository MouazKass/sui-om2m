# TR7: AdminCap Revocation — Built and Verified (not documented-around)

Status: VERIFIED on the live testnet cluster, 2026-06-24.
Package upgraded v4 -> v5: 0xe5500ac65880f0c591315794e50420c47042087c2d8d69b3b3db724e8029c6ac

## The gap (before)
grant_admin minted AdminCaps but there was NO revocation: a granted (or
compromised) cap could score forever. The invariant spec suggested documenting
this as a known limitation. Instead it was BUILT.

## The design (upgrade-compatible, Design A2)
Per-cap validity tracked in a VecSet<ID> stored as a DYNAMIC FIELD on the
existing TrustRegistry (no struct change -> compatible upgrade; AdminCap's
existing UID is used as the tracked id). Guarded score functions
(increase_guarded/decrease_guarded) call assert_cap_valid, which is:
  - FAIL-OPEN before the registry is bootstrapped (so the upgrade does not brick
    caps already in use by the running cluster), and
  - FAIL-CLOSED after bootstrap_valid_caps is called once (enforcement armed):
    a cap whose id is not in the set aborts with E_CAP_REVOKED (=5).
New functions added (adding functions is upgrade-compatible; changing an
existing public fn signature is NOT — grant_admin was kept intact and a new
grant_admin_registered added instead):
  - bootstrap_valid_caps(&AdminCap, &mut TrustRegistry, vector<ID>, ctx)
  - revoke_admin(&AdminCap, &mut TrustRegistry, cap_id: ID, ctx)
  - grant_admin_registered(&AdminCap, &mut TrustRegistry, recipient, ctx)
  - is_cap_valid(&TrustRegistry, ID): bool

## Migration performed (no cluster disruption)
1. Upgraded package to v5 via UpgradeCap 0x8c13b4... (digest EVE14k5Mznu...).
2. Re-pointed sui.package.id -> v5 on all three nodes; all booted in-cse 200;
   pre-bootstrap guarded writes succeeded (fail-open verified).
3. bootstrap_valid_caps seeded the 4 existing caps (original 0xd858c23d... +
   node caps 0x3f9f14b4..., 0x4d1dc0d7..., 0x024310d9...) and armed enforcement
   (digest 653TycpD...). A registered cap still scored afterwards (fail-closed
   but in-set) -> Success.

## Revocation proof (live)
Throwaway registered cap 0x991b870e...a5cb (minted via grant_admin_registered):
  5b BEFORE revoke: cap scores rpi2 -> Status: Success (registered & valid).
  5c revoke_admin(original cap, registry, 0x991b870e...) -> Success
     (digest 8DCumy97...). Cap removed from the valid set.
  5d AFTER revoke: the SAME cap (object still exists, still owned by caller)
     tries to score -> ABORTED in trust::assert_cap_valid with code 5
     (E_CAP_REVOKED). tx BMmQS6qx...
Revocation is targeted (per-cap), on-chain, and does not destroy the object:
the holder keeps the cap but the contract refuses its writes. The authority to
revoke is itself gated by holding a valid AdminCap.

## Note
compatible upgrade policy forbids changing existing struct fields and existing
public/entry function SIGNATURES (function bodies and new functions are fine).
The first upgrade attempt failed E03001 because grant_admin's signature had been
changed; restoring it and adding grant_admin_registered resolved it.
