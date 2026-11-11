# v10: reader access tied to the device

## 1. The gap being closed

Through v9, a protected READ of a sensor resource (`/in-cse/C<device>`) was
decided by the resource's policy and by the capability token of the node that
asked (the parent). The device's own on-chain identity (identity registry,
role 3, registered and revoked by the council since 2026-11-11) played no part:
after the council revoked a device, the bridges stopped storing its readings,
but its existing data could still be granted to readers.

## 2. Design

All changes are a **compatible upgrade** of the v8 package (package version 3):
new structs, new functions and function bodies only. No existing public
signature changes.

### 2.1 The binding (`policy.move`)

A resource can be **bound** to one device address. The binding is a dynamic
field on the shared `PolicyRegistry`, keyed by `DeviceBindingKey { resource_id }`:

```move
public struct DeviceBinding has store, drop {
    device: address,
    readers: vector<address>,   // empty = any requester that passes the chain
    policy: Policy,             // the resource's policy lives HERE once bound
}
```

Binding **moves** the resource's `Policy` out of the plain `policies` table into
the binding. That is the fence for the old bytecode (2.3).

### 2.2 The decision (`policy::evaluate_with_device`)

Step 4 of the receipt chain gains a new entry point with the same receipt in
and out:

```
identity::verify -> trust::require_min -> cap_token::validate_for_use
  -> policy::evaluate_with_device(R2, pol_reg, trust_reg, id_reg, clock) -> PolicyReceipt
  -> evaluator::decide_and_log
```

- **Unbound resource:** exactly the checks of `evaluate` (A5 trust read, ops
  mask, blackouts).
- **Bound resource:** the same checks against the binding's policy, plus, at
  decision time:
  - the device is registered in the identity registry, else
    `E_DEVICE_NOT_REGISTERED` (7). A council `id-deregister` of the device
    therefore stops every grant on its data at once;
  - it is registered as an end device (role 3), else `E_DEVICE_NOT_END_DEVICE` (8);
  - if the reader list is non-empty, the requester is on it, else
    `E_READER_NOT_ALLOWED` (9).
  - A `DeviceAccessChecked { resource_id, device, requester }` event is emitted.
- `identity::Registry` is created only by `identity::init`, so a caller cannot
  pass a registry of its own.

The plain `evaluate` (body change) refuses a bound resource with
`E_DEVICE_BOUND` (6).

### 2.3 Old bytecode stays callable: why it fails closed

On Sui the v8 and v9 package versions remain callable. Their `evaluate` body
looks the policy up in the `policies` table, and a bound resource's policy is
no longer there, so they abort `E_POLICY_MISSING` (1). Only v10 code can grant
a bound resource.

One way back exists: a **v9** `set_policy` on a bound resource would put a
policy into the table again. `set_policy` needs the `PolicyAdminCap`, which
only the council holds, so this takes a 3-of-5 vote. `scripts/v9/council.sh`
and the proofs therefore always call the newest package (`PKG_V10`), whose
`set_policy` updates the binding's policy instead.

### 2.4 Governance (`quorum.move`)

Four new council actions, executed with the wrapped `PolicyAdminCap` through
the existing `execute_policy` (body change; `assert_known_action` updated):

| id | action | arguments |
|---|---|---|
| 34 | `policy-bind-device` | text = resource, target = device |
| 35 | `policy-unbind-device` | text = resource (policy moves back to the table) |
| 36 | `policy-add-reader` | text = resource, target = reader address |
| 37 | `policy-remove-reader` | text = resource, target = reader address |

Policy writes on a bound resource (`set_policy`, `add_blackout`,
`clear_blackouts`) update the binding's policy; `remove_policy` removes the
binding with it (no policy, no access). Readers are requester addresses, i.e.
the middleware nodes that ask on behalf of an originator; per-originator
identity remains future work.

### 2.5 Plugin

`sui.policy.device.binding=true` (written by `scripts/v9/03_switch_plugin.sh
v10`) makes step 4 `evaluate_with_device` in both PTB builders
(`NativePtbBuilder.policyStep`, `PtbBuilder`). The identity registry input is
the one step 1 already uses. Off (the default, and the only valid setting
before v10) a bound resource fails closed with `E_DEVICE_BOUND`. The DENY log
names aborts 6 to 10.

## 3. Files

- `move/sources/policy.move`, `move/sources/quorum.move`
- `move/tests/device_binding_tests.move` (15 tests), `move/tests/quorum_tests.move` (+2)
- `plugin/.../sdk/NativePtbBuilder.java`, `ptb/PtbBuilder.java`,
  `config/SuiConfig.java`, `das/AbortDecoder.java`, `das/SuiDasService.java`,
  `SuiPluginActivator.java`; tests `sdk/DevicePolicyStepTest.java`,
  `das/DeviceAbortNamesTest.java`, `config/DenyConfigDefaultsTest.java` (+1)
- `scripts/v9/03_switch_plugin.sh` (`v10` mode), `scripts/v8/03_gen_config.sh`
  (`DEVICE_BINDING`), `scripts/v9/council.sh` (actions 34–37, newest package),
  `scripts/v9/upgrade_multisig.sh` (publisher signs a large tx via stdin),
  `proofs/lib_v8.sh`, `proofs/04_atomic_ptb.sh`

## 4. Verification

- Move: 158/158 (141 existing + 17 new). JUnit: 181/181 (176 existing + 5 new).
- On-chain compatibility dry run before signing: success.
- Live record: `ROLLOUT_V9.md`, section "v10: reader access tied to the device".
