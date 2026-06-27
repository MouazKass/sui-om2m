# AdminCap Inventory (trust module, package original-id 0xcba39e8b...)

Snapshot 2026-06-27. All caps are trust::AdminCap. The TR7 validity set
(dynamic field tr7_valid_caps on the TrustRegistry) gates which caps may
score once the registry is bootstrapped (fail-closed).

## In-use per-node caps (configured in each node's sui.properties trust.admin.cap.id) — KEEP
  rpi1  0x3f9f14b4a1fde7b77c386a22b054a8a58b03781e02d2b59b473a78c83a48b121
  rpi2  0x4d1dc0d77ec0edd6e17b592d8a2ab7fd8368c70ddf9a1f34dc067dc828fab9ca
  rpi3  0x024310d94fa96c02cb3c18e5219ecfb123d8e4366a08e76d61e999749c8f8538

## Original / bootstrap authority cap (publisher 0xb87fb2af...) — KEEP
  0xd858c23d4e333843bc09114985c752a7f482b8950db1059fee07b0478c58f568

## Duplicate per-node caps (extra grants, unused by config) — inert, harmless
  rpi1  0x0807e2b1ddaa4f366664c13aa9043308bfcea984b3b4f36e603f5f68fcbe48fa
  rpi2  0xbac06c3741e13f22027c989856a910b2cb7c868a51d86bb2766bd26067df0e2b
  rpi3  0xb01a5e5b7d226c4a3fdcdee4ec840396619a482349e5640d99a51586c6484434
  These do not affect any invariant. trust::AdminCap has no burn/destructor,
  so removal would require transferring to a burn address (irreversible, no
  functional benefit). Left in place intentionally.

## Revoked throwaway (publisher) — neutralized via TR7
  0x991b870e96fc18f92ae357cd2a90f282dbc320dfd7470a0d10c90ddb2bcba5cb
  Used in the TR7 revocation demo (TR7_EVIDENCE.md): granted via
  grant_admin_registered, scored once, then revoke_admin'd. It is removed
  from tr7_valid_caps, so guarded score writes with it abort E_CAP_REVOKED(5).
  Already neutralized; the object itself is inert.

## Note
PolicyAdminCap (policy module) lives separately on the publisher wallet:
  0x5014cfabcf799c405b7989c9438d84e55ee5a1941cf95eebc87ba8947ad66883
  (used for set_policy/add_blackout in PO1/PO2 evidence — PO4 authority sep.)

## UPDATE 2026-06-27 — v6 upgrade + burn
v6 package: 0xb579914d317ebd8bb6ef6d0b59d2f80a4a81fc731917840dd01a4daa64180899
burn_admin (self-burn AdminCap destructor) deployed in v6.
- Revoked throwaway 0x991b870e... BURNED via burn_admin
  (digest 6HUMB4jwqCkLcDccGX2Gnj4bqSddLQrq4aGbjv1Cfeya, AdminCapBurned emitted).
  Object destroyed (object::delete), not just revoked. Full lifecycle complete:
  mint -> grant -> revoke -> burn.
- Node duplicate caps (0x0807e2b1/rpi1, 0xbac06c37/rpi2, 0xb01a5e5b/rpi3) left
  in place: owned by node wallets (self-burn requires each node's key), and
  inert/harmless. Documented, not burned.
