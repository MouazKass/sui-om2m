# AdminCap Inventory (trust module, package original-id 0xcba39e8b...)

## CURRENT (v9, 2026-11-10) - read this first; everything below is history

Package original-id `0x88f0b0f7...` (v8 fresh publish), upgraded to v9 `0x5121fa28...`.
The TrustRegistry is governed by the 3-of-5 council `0xd98ce113...24e0`
(`scripts/v9/council.sh`). IDs: `deploy/v8/deployment.env`, `deploy/v9/deployment.env`.

| Cap | Holder | State |
|---|---|---|
| trust AdminCap rpi1-rpi5 (`ADMINCAP_RPI1..5` / `TRUST_ADMIN_CAP_<NAME>`) | each node, own key | valid; also each node's council credential |
| trust AdminCap genesis `0x33e6daad...8cf0` (`TR_ADMIN_CAP`) | publisher | **REVOKED** by council proposal 5, execute tx `CHDdqJhsuabCV44onWAN82tpmWAeBmCthbSUKtyyxjG2`; any guarded use aborts 5 |
| identity AdminCap | consumed by `create_council` | gone; registration is council action 20/21 |
| PolicyAdminCap, IssuerCap, ClusterAdminCap | inside the council | council actions 30-33, 40, 50 |
| UpgradeCap | publisher | option A; multisig pending (V9_DESIGN.md section 5) |

Grants and revocations of other nodes' caps are council-only (`E_GOVERNED` = 8 for any
single cap); a cap may still revoke itself. Proof 09's throwaway caps are granted,
revoked and burned on each run. Record: `ROLLOUT_V9.md` section 6.


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

## UPDATE 2026-11-09 — v8 security batch: ALL ids above become obsolete

### Every capability object id in this file is historical as of v8

The security-fixes-v8 batch is a **fresh publish**, not an upgrade, so it has
its own type root. The AdminCaps, PolicyAdminCap and UpgradeCap listed above are
`trust::AdminCap` / `policy::PolicyAdminCap` of the **v1-v6 package**, and the
v7 deployment had its own separate set again. None of them is accepted by a v8
function: passing one is a type/argument error, not a clean Move abort.

Keep this inventory for provenance — the TR7 revocation demo and the v6
burn_admin lifecycle are cited in evidence files — but after the v8 publish:

- do not put any id from this file into a node's `sui.properties`
  (`trust.admin.cap.id`);
- a new inventory section must be written listing the v8 genesis AdminCap, the
  v8 per-node caps, and the new PolicyAdminCap / AuditAdminCap / UpgradeCap.

### `grant_admin` and `grant_admin_registered` now share one mint path

In v6/v7 these were two different implementations, and only one of them was
revocable:

- `grant_admin(_admin, recipient, ctx)` minted a bare AdminCap and **never
  touched `tr7_valid_caps`**. Since revocation works by removing an id from that
  set, a cap minted this way could never be revoked — it was permanently outside
  TR7. The two signatures had to diverge because TR7 shipped as a compatible
  upgrade, which forbids changing an existing public signature (see
  TR7_EVIDENCE.md).
- `grant_admin_registered(_admin, registry, recipient, ctx)` did register the
  new id, but took the granting cap as `_admin` and never validated it, so a
  **revoked** admin could keep minting fresh valid-looking caps indefinitely.

In v8 both are one-line delegations to a single private
`mint_and_register(admin, registry, recipient, ctx)` which:

1. calls `assert_cap_valid(admin, registry)` on the **granting** cap first, so a
   revoked admin cannot launder its lost authority into a new cap; then
2. mints, inserts the new cap's id into `tr7_valid_caps`, and transfers.

`grant_admin` therefore gained a `&mut TrustRegistry` parameter. That is a
breaking signature change, admissible only because v8 is a fresh publish. Any
script calling `grant_admin` (e.g. `scripts/grant-admins.sh`) must be updated to
pass the TRUST_REG object.

Net effect: there is exactly one way to mint an AdminCap on v8, every cap it
produces is tracked in the validity set, and every cap it produces is therefore
revocable via `revoke_admin`. See A8 in `SECBATCH-2026-11_EVIDENCE.md`
(tests `a8_grant_admin_registers_new_cap_in_validity_set` and
`a8_cap_minted_by_grant_admin_is_revocable`).

### Cap validity is FAIL-CLOSED from genesis on v8

On v5-v7, `assert_cap_valid` was fail-open until an operator ran
`bootstrap_valid_caps` once, because TR7 arrived as an upgrade onto a live
cluster and could not be allowed to brick caps already in use.

v8's `trust::init` registers the genesis AdminCap and sets the
`tr7_bootstrapped` marker **in the publish transaction itself**. So:

- enforcement is armed before any other transaction can run; the fail-open
  window is not merely unused on v8, it is not observable;
- **no `bootstrap_valid_caps` call belongs in the v8 runbook**;
- any cap not in `tr7_valid_caps` aborts `trust::E_CAP_REVOKED` (code 5) — and
  in v8 that now includes `add_node` (A1), the bootstrap path (A2) and both
  grant paths (A8), not only the guarded score writes.

This matters operationally: on v8 a wrong `trust.admin.cap.id` fails closed
immediately with abort 5, whereas on a pre-bootstrap v5-v7 registry the same
mistake would have silently succeeded.
