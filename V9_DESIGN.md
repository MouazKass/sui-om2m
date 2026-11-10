# v9: k-of-n governance (paper limitation 2) and a multisig UpgradeCap

Status markers: `[x]` done and verified, `[ ]` pending, `[!]` needs Mouaz (or
Hamza, or the third signer).

v9 is a **compatible upgrade** of the live v8 package
(`0x88f0b0f7…62f1`). It adds one module (`quorum.move`), adds new functions to
`trust.move` and `failover.move`, and changes four `trust.move` function
bodies. No public signature or struct layout changes. Nothing in this document
has been published or signed. All results below are local.

---

## 1. The problem being closed

**Limitation 2 as the paper states it:** registering a node, issuing a token and
writing a policy each need one capability held by one publisher account.

**The sharper gap the paper review found.** In v8 every node holds a trust
`AdminCap`, and `trust::revoke_admin` accepts *any* valid cap revoking *any
other* cap. So one compromised node can:

- revoke all honest nodes' caps, locking them out of score writes for good;
- mint itself fresh caps with `grant_admin` / `grant_admin_registered`;
- un-revoke a cap with `bootstrap_valid_caps`, which re-inserts any id;
- create trust entries for nodes nobody approved with `add_node`.

None of this needs the publisher. One node's key is enough.

## 2. Design

### 2.1 The Council
`quorum::Council` is one shared object holding:
- `members`, a `VecSet<address>`;
- the threshold `k`;
- a monotonic proposal counter;
- `Table<u64, Proposal>`;
- the IDs of the identity and trust registries it governs;
- a `version` field (§2.6).

| Property | How it is enforced |
|---|---|
| **Membership reuses node identities** | Every member must be registered in `identity::Registry` as IN-CSE or MN-CSE (`E_NOT_ELIGIBLE`). AEs and unknown addresses are rejected. Duplicates are rejected (`E_DUPLICATE_MEMBER`). |
| **Approvals reuse AdminCaps** | `propose` / `approve` require the member's own `trust::AdminCap`, which must still be valid (`E_CAP_INVALID`). Sui only accepts an owned object from its owner, so the cap must belong to the signer. The cap id is recorded with the approval. |
| **Threshold** | `2 ≤ k ≤ n` and `2k > n` (strict majority), checked at creation, `SET_THRESHOLD`, `ADD_MEMBER` and `REMOVE_MEMBER` (`E_BAD_THRESHOLD`). `k = 1`, i.e. one key again, cannot be represented. Two disjoint coalitions can never both reach quorum. |
| **Double approval** | One approval per address (`E_ALREADY_APPROVED`). The proposer's approval is recorded at `propose`. |
| **Replay** | Ids come from a counter and are never reused. `execute_*` removes the proposal before acting, so a second execute aborts with `E_NO_PROPOSAL`. |
| **Expiry** | Each proposal has `expires_ms = created + ttl`, with `0 < ttl ≤ 7 days` (`E_BAD_TTL`). Approving or executing at or after expiry aborts (`E_EXPIRED`). Anyone can `discard_expired`. |
| **Stale approvals** | Approvals are counted at **execution**. One counts only if the approver is *still a member* and *the cap it presented is still valid*. Removing a member or revoking its cap voids every approval it gave, including on pending proposals. |
| **Typed execution** | Each `execute_*` accepts only its own action codes (`E_WRONG_ACTION`). A membership proposal can't run through `execute_trust`. The executor must be a member. |

### 2.2 What it guards

| Action | Code | Executed through | Authority used |
|---|---|---|---|
| add / remove member, set k | 1 / 2 / 3 | `execute_membership` | the council itself |
| **grant trust AdminCap** | 10 | `execute_trust` | `trust::governed_grant` (package-only) |
| **revoke a peer's trust AdminCap** | 11 | `execute_trust` | `trust::governed_revoke` (package-only) |
| seed a trust entry | 12 | `execute_trust` | `trust::governed_add_node` (package-only) |
| register / deregister node | 20 / 21 | `execute_identity` | wrapped `identity::AdminCap` |
| set / remove policy, add / clear blackouts | 30–33 | `execute_policy` | wrapped `PolicyAdminCap` |
| mint capability token | 40 | `execute_mint` | wrapped `IssuerCap` |
| **cluster config** (trust gate) | 50 | `execute_cluster` | wrapped `ClusterAdminCap` for that cluster |

`create_council` **consumes** the package's only `identity::AdminCap`.
`identity::init` runs once, so at most one Council can ever exist per
deployment, and nobody can set up a rival council. The `PolicyAdminCap`,
`IssuerCap` and `ClusterAdminCap` are deposited with `deposit_*`. Once
deposited they are wrapped inside the Council, so no account holds them and
only an executed proposal can use them.

### 2.3 How trust.move changes (all body-only or additive)

`create_council` calls `trust::set_governed`, which is one-way: there is no
"un-govern" function. After that:

| v8 entry point (signature unchanged) | v9 behaviour once governed |
|---|---|
| `revoke_admin(admin, reg, cap_id)` | **peer** cap → `E_GOVERNED` (8). **Own** cap (`cap_id == id(admin)`) → still allowed: a node that suspects its key leaked must be able to give up its own power alone. |
| `grant_admin`, `grant_admin_registered` | `E_GOVERNED` |
| `bootstrap_valid_caps` | `E_GOVERNED` (otherwise any valid cap could re-insert a revoked id) |
| `add_node` | `E_GOVERNED` |
| `increase_guarded`, `decrease_guarded` | **unchanged.** Score writes stay per-node peer attestation, bounded by A12 (15 points / 60 s). That is limitation 1, which is a different property. |
| `burn_admin` | unchanged (a cap can only burn itself) |

The coordinator's options were "a body-only change" or "a new guarded entry
plus disabling the old one". v9 uses the body-only change: the
existing entry points keep their names and signatures and gain a guard, and
the same operations are reachable through new `public(package)` functions that
only `quorum.move` calls.

### 2.4 Fencing off the old v8 bytecode (the part a naive upgrade gets wrong)

**On Sui, old package versions stay callable.** After the upgrade, anyone can
still call `0x88f0…::trust::revoke_admin`. That runs **v8's** body, which has
no governed guard, so body-only guards alone would leave the v8 attack intact.

v9 closes this without touching v8:
- Every v8 cap-gated path starts with v8's `assert_cap_valid`. That function
  fails closed when the registry is bootstrapped but the validity set is
  missing under the key `tr7_valid_caps`.
- `set_governed` **moves** the set to a new key (`v9_valid_caps`) and leaves
  the bootstrapped marker in place.
- v9 code reads the set through `caps_key()`, which follows the move.

Result: through the v8 package id, every v8 path that takes an AdminCap aborts
with `E_CAP_REVOKED` (5), even for caps that are valid under v9. That covers
`revoke_admin`, `grant_admin*`, `bootstrap_valid_caps`, `add_node` and both
score writes. Through the v9 id, the rules of §2.3 apply.

The wrapped identity / policy / issuer / cluster caps need no fence: no
account holds them, so nobody can pass them to a v8 function.

**Consequence for the plugin:** score writes must go through the v9 package
id *before* governance is armed, or they start aborting.

`sui.package.id` is mostly used as a call target, with one exception:
`NativePtbBuilder.fetchParentPoa` builds the dynamic-field type tag
`<sui.package.id>::failover::ParentPoaKey`. After an upgrade, types keep the
**original** id (`0x88f0…`). If the plugin only switches `sui.package.id` to
`PKG_V9`, the PoA read finds nothing and followers stop learning the parent's
address. Before phase F, the plugin owner must make `fetchParentPoa` also try
the original id, for example through a new `sui.package.original.id` key
(defaulting to the v8 id), the same way it already tries `LEGACY_V2_PKG`.
v9 Move code can't fix this; it is a plugin change outside this work.

### 2.5 How this closes limitation 2
After phase G of the runbook:
- No account holds the identity, policy, issuer or cluster capability.
- No single trust AdminCap can grant, revoke a peer, un-revoke or seed.
- Each of those needs `k` of the `n` middleware nodes, each signing with its
  own key **and** a still-valid cap.
- One compromised node (or the publisher's key alone) can no longer register
  a node, issue a token, write a policy, change the trust gate, or lock its
  peers out.
- Compromising `k` nodes is the new bar: 2 of 3 on today's testbed, and a
  majority on the 5-node cluster.

The remaining single key is the package **UpgradeCap**. An upgrade could
replace `quorum.move`. It therefore moves to a 2-of-3 multisig (§5), which
puts the same k-of-n bar on code changes.

Suggested replacement for the paper's second limitation:
> Administrative operations (registering a middleware node, issuing a
> capability token, writing an access-control policy, changing the failover
> trust gate, and granting or revoking a trust administrative capability)
> require approval by a strict majority of the registered middleware nodes,
> each signing with its own key and a valid trust administrative capability.
> The package upgrade capability is held by a 2-of-3 multisig address.
> Compromising one middleware node or one operator key is therefore not
> sufficient to perform any of these operations.

### 2.6 Future upgrades
- `Council.version` uses the versioned-object pattern. `quorum.move` checks it
  on every propose, approve, execute and deposit, so a later upgrade can
  migrate the version and fence v9's council code the same way §2.4 fences
  v8.
- In `trust.move` the same key-move trick can be repeated: a v10 moves the
  set to `v10_valid_caps`.

### 2.7 Deliberately out of scope
- **`cap_token::revoke`.** It consumes the token by value, so only its owner
  can call it. Tokens are bounded by `expiry_ms`, `max_uses` and evolution.
- **`audit::AuditAdminCap`.** The DAS uses it on the hot path
  (`log_denied_authorized`). It only appends denial records and cannot decide
  a request.
- **Liveness if `n − k + 1` members die.** Governance stalls until they come
  back. The multisig UpgradeCap is the break-glass path: an upgrade can add a
  recovery function. This is a deliberate trade: no single party can
  override the council.

### 2.8 Parent PoA bound to the parent (finding F2)

**Live symptom on v8.**
- After rpi3 took over, followers kept reading rpi1's old PoA.
- `claim_parent` never touched the `ParentPoaKey` field.
- Nothing recorded who had written that field.
- The plugin now works around it; the root cause is fixed in failover.move.

**Fix in failover.move (compatible):**

| Item | Change | Kind of change |
|---|---|---|
| `claim_parent` | Calls `clear_poa` atomically with the parent change, removing the old parent's PoA and its owner record. The new parent re-advertises. | body-only |
| `set_parent_poa` | Already asserted `sender == current_parent` (`E_NOT_PARENT`, 6). It now also records the publisher under the new `ParentPoaOwnerKey` field. | body-only |
| `parent_poa` | Returns empty when the recorded owner isn't the current parent. | body-only |
| `parent_poa_owner` | New public read: returns `@0x0` when no owner is recorded. | new function |

**Why the read check matters.** A claim made through the still-callable v8
`claim_parent` doesn't clear the field. Even then, the v9 read won't hand out
a PoA bound to the deposed parent.

**Unchanged:** the `ParentPoaKey` value type (`vector<u8>`). Off-chain readers
of the raw field, like the plugin, keep working, and see the field disappear on
takeover.

**Residual:**
- The plugin reads the raw field over GraphQL, not `parent_poa`.
- For a claim made through the v8 id it only gets the owner check if it also
  compares the `ParentPoaOwnerKey` field with `current_parent`. **Done in the
  plugin (2026-11-10):** `fetchParentPoa` ignores a PoA whose owner is not the
  current parent.
- After phase F every honest claim goes through v9.

### 2.9 DENY batches on the audit trail (finding F3)

**The finding.** Every DENY was a submitted transaction that aborted and still
paid about 1 mSUI, so a sensor mapped to rpi3 could drain rpi3's gas by
repeating a forbidden request. The abort also rolled back any audit write, so
denials never reached the AuditTrail. The only external denial writer,
`evaluator::log_denied_authorized`, needs the publisher's `AuditAdminCap`.

**v8 half: fixed and deployed on 2026-11-10, no contract change.** The plugin
simulates each decision for free and submits only a simulated GRANT. Repeat
DENYs are answered from a 10 s local cache, an originator with 30 verdict
DENYs in a minute is throttled for the rest of that minute, and every DENY goes
to a JSON-lines log. See ROLLOUT_V8.md, "F3".

**v9 half: this section.** One compact on-chain record per window of each
node's DENY log:

| Item | Change | Kind |
|---|---|---|
| `evaluator::log_deny_batch(IdentityReceipt, &identity::Registry, &trust::AdminCap, &TrustRegistry, &mut AuditTrail, window_start_ms, window_end_ms, deny_count, distinct_keys, digest, &Clock)` | The only way in. The node is the signer (the receipt comes from `identity::verify`), it must be an IN-CSE or MN-CSE (`E_NOT_MIDDLEWARE`, 100), and it must pass a trust AdminCap that `trust::is_cap_valid` accepts (`E_NODE_CAP_INVALID`, 101; governed-aware) | new public function |
| `audit::log_deny_batch` | Validates and stores: 32-byte digest (`E_BAD_DIGEST`, 2), `0 < distinct <= count` (`E_EMPTY_BATCH`, 3), `start < end`, window at most 24 h and ending no more than 60 s ahead of the chain clock (`E_BAD_WINDOW`, 4), at most one batch per node per 5 min (`E_BATCH_TOO_SOON`, 5), no overlap with that node's previous window (`E_WINDOW_OVERLAP`, 6). Emits `DenialsLogged`, keeps a 256-entry ring | new `public(package)` function (A7) |
| `DenyBatch`, `DenyLog`/`DenyLogKey`, `DenyNodeState`/`DenyNodeKey`, `DenialsLogged` | Stored as dynamic fields on the existing AuditTrail, so its layout is untouched | new structs |
| `audit::deny_batch_count`, `latest_deny_batch`, `deny_batch_min_interval_ms` | Reads | new public functions |

**What a batch proves.** The digest is the SHA-256 of the window's exact DENY
log lines (each line's UTF-8 bytes plus `
`, in order), and the log writes a
`{"batch":{...}}` marker with the same digest at each window boundary. Anyone
holding a node's log can recompute every anchored window, so a later edit or
deletion is detectable, and the per-window count is public. The batch does
not reveal originators or resources on-chain.

**Cost.** One transaction per node per flush interval (default 15 min, floored
at the contract's 5 min), and only for windows that contain a DENY. A flood of
denials costs at most that single transaction, never one per request. The
plugin pre-checks the batch like every decision, so a batch the contract would
refuse is never paid for.

**Plugin side (shipped in the v8 bundle, off).** `DenyBatchFlusher` closes the
window on each tick and submits at most one pending batch, oldest first.
Transport errors are kept for the next tick. A contract refusal is retried 3
times, then dropped with a warning; the lines stay in the local log. The queue
is bounded at 16. It is gated by `sui.das.deny.audit.flush.enabled=false`,
which stays off on v8 because the function exists only in v9. It is turned on
in phase F below.

## 3. Files

| File | Change |
|---|---|
| `move/sources/quorum.move` | **new**: Council, proposals, `execute_*`, `deposit_*`, reads |
| `move/sources/trust.move` | errors 8/9, `V9_VALID_CAPS_KEY`, `GOVERNED_KEY`; guards in `add_node`, `mint_and_register`, `bootstrap_valid_caps`, `revoke_admin`; private helpers `insert_node`, `mint_register_transfer`, `remove_cap_id`, `caps_key`; `public(package)` `set_governed`, `governed_grant`, `governed_revoke`, `governed_add_node`; public `is_governed`; `#[test_only] legacy_v8_cap_check_for_testing` |
| `move/sources/failover.move` | new public read `cap_cluster(&ClusterAdminCap)`; F2: body changes in `claim_parent`, `set_parent_poa`, `parent_poa`; new struct `ParentPoaOwnerKey`, new public read `parent_poa_owner`, private `clear_poa` |
| `move/tests/quorum_tests.move` | **new**: 41 tests |
| `move/tests/parent_poa_tests.move` | **new**: 6 tests (F2) |
| `move/sources/audit.move` | F3: errors 2-6, `DenyBatch`, `DenyLog`/`DenyLogKey`, `DenyNodeState`/`DenyNodeKey`, event `DenialsLogged`; `public(package) log_deny_batch`; public reads `deny_batch_count`, `latest_deny_batch`, `deny_batch_min_interval_ms` |
| `move/sources/evaluator.move` | F3: errors 100/101; new public `log_deny_batch` (receipt-gated) |
| `move/tests/deny_batch_tests.move` | **new**: 17 tests (F3) |

`Move.lock`, `Move.toml` and `Published.toml` are unchanged. Everything was
built in a WSL copy.

## 4. Verification (local, 2026-11-10)

- [x] `sui move build`: exit 0. The only warnings are W04037 deprecations
  (`exists_`, `size`), a style the package already uses.
- [x] `sui move test`: **137 / 137** (was 73 / 73). The 73 existing tests
  pass unchanged, plus 41 quorum tests, 6 F2 tests and 17 F3 tests.
- [x] **Mutation checks.** Each guard was reverted on its own; each time the
  targeted test failed and every other test passed:

  | Reverted guard | Tests that failed |
  |---|---|
  | governed guard made a no-op | all 6 single-cap and second-council tests |
  | approval recount skips cap validity | `approval_from_since_revoked_cap_stops_counting` |
  | set copied instead of moved | `legacy_v8_paths_fail_closed_after_governance` |
  | self-revoke exception removed | `self_revoke_stays_unilateral_when_governed` |
  | peer guard removed | `single_cap_revoke_admin_rejected` |
  | F2: `claim_parent` doesn't clear | `takeover_clears_the_old_parents_poa` |
  | F2: owner not recorded | `poa_is_bound_to_the_parent_that_set_it`, `new_parent_readvertises_after_takeover` |
  | F3: role check removed | `an_ae_cannot_anchor_batches` |
  | F3: cap check removed | `a_revoked_cap_cannot_anchor_batches` |
  | F3: 5 min interval removed | `a_second_batch_inside_the_interval_is_rejected` |
  | F3: overlap check removed | `an_overlapping_window_is_rejected` |
  | F3: digest length check removed | `a_short_digest_is_rejected` |
  | F3: future-window check removed | `a_window_ending_in_the_future_is_rejected` |

- [x] **Upgrade compatibility (offline).** Every struct (name, abilities,
  fields) and every `public` / `entry` signature of all 8 v8 modules is present
  unchanged in v9. Additions are `failover::cap_cluster`,
  `failover::parent_poa_owner`, the struct `failover::ParentPoaOwnerKey`,
  `trust::is_governed`, the new module `quorum`, and for F3
  `evaluator::log_deny_batch`, `audit::{deny_batch_count, latest_deny_batch,
  deny_batch_min_interval_ms}` and six new audit structs (re-checked
  2026-11-10 against the deployed v8 source, b08b3e3). **RESULT: COMPATIBLE.** The baseline is the real
  deployed package: the 8 modules fetched from testnet over GraphQL are
  byte-identical to a build of git HEAD. Script in Appendix A.
- [ ] **On-chain compatibility check** (`sui client upgrade --dry-run`).
  Blocked by the CLI: 1.74.0 supports protocol ≤ 127, testnet is at
  **140**, and the dry run panics with `Network protocol version is
  ProtocolVersion(140), but the maximum supported version by the binary is
  127` before it builds a transaction. **Needed: Sui CLI `testnet-v1.83.1`**
  (protocol 140; `testnet-v1.83.0` is also 140, `1.82.2` is only 139).

### Test list (`quorum_tests.move`)

**Positive controls (13)**
- `create_council_wraps_caps_and_arms_governance`
- `revoke_admin_with_two_of_three`
- `grant_admin_with_two_of_three`
- `onboard_node_identity_then_trust`
- `deregister_via_council`
- `policy_write_via_council`
- `token_mint_via_council`
- `cluster_gate_via_council`
- `grow_to_four_members_after_raising_threshold`
- `score_writes_stay_per_node_when_governed`
- `expired_proposal_can_be_discarded`
- `self_revoke_stays_unilateral_when_governed`
- `legacy_v8_check_passes_before_governance`

**Single-holder paths are closed (expected_failure)**

| Test | Aborts with |
|---|---|
| `single_cap_revoke_admin_rejected` (the review's attack) | trust 8 |
| `single_cap_grant_admin_rejected` | trust 8 |
| `single_cap_grant_admin_registered_rejected` | trust 8 |
| `single_cap_unrevoke_via_bootstrap_rejected` | trust 8 |
| `single_cap_add_node_rejected` | trust 8 |
| `second_council_cannot_take_over` | trust 8 |
| `legacy_v8_paths_fail_closed_after_governance` | trust 5, through the v8 code path |

**Proposal-flow attacks (expected_failure)**

| Test | Aborts with |
|---|---|
| `one_approval_is_not_quorum` | 4 |
| `double_approval_rejected` | 2 |
| `replay_of_executed_proposal_rejected` | 5 |
| `approve_after_expiry_rejected` | 3 |
| `execute_after_expiry_rejected` | 3 |
| `non_member_cannot_propose` | 1 |
| `non_member_cannot_execute` | 1 |
| `member_with_revoked_cap_cannot_approve` | 9 |
| `approval_from_since_revoked_cap_stops_counting` | 4 |
| `approval_from_removed_member_stops_counting` | 4 |
| `proposal_cannot_run_through_wrong_executor` | 6 |
| `unknown_action_rejected` | 6 |
| `ttl_above_max_rejected` | 10 |
| `cannot_deregister_a_sitting_member` | 11 |

**Threshold and membership invariants (expected_failure)**

| Test | Aborts with |
|---|---|
| `threshold_of_one_rejected` | 7 |
| `non_majority_threshold_rejected` | 7 |
| `ae_cannot_be_member` | 8 |
| `unregistered_address_cannot_be_member` | 8 |
| `duplicate_member_rejected` | 16 |
| `adding_member_that_breaks_majority_rejected` | 7 |
| `removing_below_threshold_rejected` | 7 |

## 5. Moving the UpgradeCap to a 2-of-3 multisig

Signers (weight 1 each, threshold 2): **Mouaz**, **Hamza** and a **third
signer**. The third can be a cold key kept offline, but not the same machine
as Mouaz's key.

Run these with CLI ≥ `testnet-v1.83.1`. Each signer's private key stays on its
own machine. Only public keys and signatures are exchanged.

```bash
# 1. [!] Each signer, on their own machine: create (or pick) an ed25519 key and
#    send the Base64 `flag||pk` from the "publicBase64Key" column to Mouaz.
sui keytool generate ed25519          # skip if using an existing key
sui keytool list                      # copy publicBase64Key

# 2. Derive the multisig address (anyone can run this; no secrets involved).
PK_MOUAZ=...; PK_HAMZA=...; PK_THIRD=...
sui keytool multi-sig-address --pks $PK_MOUAZ $PK_HAMZA $PK_THIRD \
    --weights 1 1 1 --threshold 2
# -> record as UPGRADE_MULTISIG in deploy/v9/deployment.env

# 3. Fund it with gas (an upgrade costs ~0.1–0.5 SUI on testnet).
sui client transfer-sui --to $UPGRADE_MULTISIG --sui-coin-object-id <coin> \
    --amount 1000000000 --gas-budget 10000000

# 4. [!] Publisher (WSL), single signature: hand over the UpgradeCap.
sui client transfer --to $UPGRADE_MULTISIG --object-id $UPGRADE_CAP --gas-budget 10000000
sui client object $UPGRADE_CAP        # owner must now be AddressOwner($UPGRADE_MULTISIG)

# 5. Any later upgrade: build the unsigned tx with the multisig as sender.
cd move
TX=$(sui client upgrade --upgrade-capability $UPGRADE_CAP --sender $UPGRADE_MULTISIG \
       --gas-budget 500000000 --serialize-unsigned-transaction)

# 6. [!] Two signers, each on their own machine:
sui keytool sign --address <their-address> --data "$TX"   # -> suiSignature

# 7. Combine and execute (anyone).
SIG=$(sui keytool multi-sig-combine-partial-sig --pks $PK_MOUAZ $PK_HAMZA $PK_THIRD \
        --weights 1 1 1 --threshold 2 --sigs $SIG_A $SIG_B --json | jq -r .multisigSerialized)
sui client execute-signed-tx --tx-bytes "$TX" --signatures "$SIG"
```

**Notes**
- Verify on 1.83.1 that `upgrade --sender` and
  `multi-sig-combine-partial-sig --json` produce the same output fields as on
  1.74.0, where both flags exist.
- Optional hardening: the multisig can later call
  `sui::package::only_dep_upgrades` or `make_immutable`. That would block
  future bug fixes, so it is not recommended yet.

## 6. Rollout runbook (mirrors ROLLOUT_V8.md)

### A. Code readiness (local): done
- [x] 137 / 137 Move tests, mutation-checked; offline compatibility COMPATIBLE.

**Scripts (2026-11-10).** Every phase below has a script in `scripts/v9/`.
Each one is idempotent, uses `set -euo pipefail`, reads the generated env
files, and dry-runs by default. One-way steps also need a typed confirmation.

| Phase | Script | Runs in | Signs? |
|---|---|---|---|
| C | `00_multisig.sh <pk1> <pk2> <pk3> [k]` → `deploy/v9/multisig.env` | anywhere | no |
| D | `01_transfer_upgradecap.sh [--execute]` | WSL (publisher) | publisher, once |
| E | `02_upgrade.sh dry-run \| build \| combine S1 S2 \| execute` | WSL | two signers, off-box |
| F | `03_switch_plugin.sh status \| v9 \| flush-on \| v8` | Git Bash | node keys (normal operation) |
| G | `04_council.sh [--execute]` | WSL (publisher) | publisher |
| H | `05_verify.sh` (read-only, valid at every phase) | WSL | no |
| – | `rehearse_multisig.sh`: C + E-combine with throwaway keys | WSL | no |

`03_switch_plugin.sh` writes `deploy/v9/plugin-target.env`, and
`scripts/v8/03_gen_config.sh` reads it (`CALL_PKG`, `DENY_FLUSH`). When that
file is absent, the generated config is byte-identical to before (checked
2026-11-10). `sui.package.original.id` always stays `$PKG_V8`. The guide for
the other two signers is `V9_SIGNERS.md`. The evidence logs are in
`evidence/v9-prep/`.

### B. Toolchain: [!] WSL on the publisher laptop: done 2026-11-10
- [x] Sui CLI `testnet-v1.83.1` installed side by side at
  `~/sui-cli/1.83.1/sui` (the release tarball's SHA-256 `1a59344f…8347`
  matched the GitHub release digest). 1.74.0 is still at
  `/usr/local/bin/sui`. The v9 scripts pick 1.83.1 automatically (`lib.sh`),
  and set `SUI=` to override.
- [x] `sui move test` on 1.83.1: **137 / 137**. The new framework only adds
  deprecation warnings (`dynamic_field::exists_` → `exists`, `vec_*::size` →
  `length`). These are not errors and are left as is, so the bytecode stays
  identical to the reviewed source.
- [x] **On-chain upgrade dry run: success.** The CLI's on-chain compatibility
  check accepts v9 as an upgrade of v8: version 2, 9 modules including
  `quorum`. The estimated net cost is **0.2070 SUI** (computation 0.0019,
  storage 0.2068, rebate 0.0016), so 1 SUI on the multisig covers it with
  room to spare. See `evidence/v9-prep/upgrade_dryrun.log`.
- [x] `move/Move.lock` and `Published.toml` are unchanged. The scripts build
  from a temp copy, so the newer CLI never rewrites the committed files.
- [x] Multisig rehearsal with three throwaway keys: 14 / 14 checks pass
  (`evidence/v9-prep/multisig_rehearsal.log`). The checks cover:
  - address derivation, which matches the CLI;
  - idempotence;
  - refusing duplicate keys, threshold 1, non-ed25519 keys and two keys;
  - combining signatures pasted in the wrong order;
  - refusing a single signature, the same signer twice, and a non-member's
    signature.
- [x] The peer-revoke attack, run as a free dev-inspect against live v8 (rpi1
  revoking rpi2's cap), still **succeeds** today. That is the gap phase G
  closes. `05_verify.sh` prints it while governance is not armed.

### C. Multisig: [!] all three signers
- [ ] §5 steps 1–3. Record `UPGRADE_MULTISIG` and the three public keys
  (public keys are not secret) in `deploy/v9/deployment.env`.

### D. Hand over the UpgradeCap: [!] publisher
- [ ] §5 step 4, then confirm the owner on-chain.
- [ ] From now on, the publisher alone cannot upgrade.

### E. Upgrade to v9: [!] two signers
- [ ] Run `sui client upgrade --dry-run --sender $UPGRADE_MULTISIG …` first.
  This is the on-chain compatibility check. It must pass.
- [ ] Run §5 steps 5–7. Record `PKG_V9`.
- [ ] Nothing changes in behaviour yet. Governance is not armed, and the
  plugin still calls v8.

### F. Point the plugin at v9
- [x] **Prerequisite (plugin change, §2.4): done 2026-11-10, deployed (bundle `3aec03c3`).**
  Move type names now use `sui.package.original.id` (type origin; defaults to
  `sui.package.id`), call targets keep `sui.package.id`. `fetchParentPoa` spells
  `<original>::failover::ParentPoaKey`, reads `<original>::failover::ParentPoaOwnerKey`
  when present and ignores a PoA whose owner is not `current_parent`; with no owner
  field (v8) it behaves as before. The audit found no other plugin site that builds a
  package type string (all other uses of `sui.package.id` are call targets).
  `03_gen_config.sh` now emits `sui.package.original.id=$PKG_V8`, which must
  **stay** `$PKG_V8` when `sui.package.id` moves to `$PKG_V9`. Tests:
  `ParentPoaTypeOriginTest` (10, against a stub GraphQL endpoint),
  `PackageOriginalIdTest` (3), mutation-checked; suite 120/120. Live on v8:
  all three nodes read the PoA under the v8 tag exactly as before
  (`evidence/v8-measurements/verify_after_typeorigin.log`).
- [ ] Set `sui.package.id=$PKG_V9` through `03_gen_config.sh`, then
  `04_cutover.sh config` → `redeploy` → `verify`.
- [ ] Verify: a C2 GRANT, a trust delta landing on-chain from each node, and a
  lease anchor. All of them must show the **v9** package in the tx's
  `MoveCall`.
- [ ] F3: once a v9 GRANT is verified, set `sui.das.deny.audit.flush.enabled=true`
  in `03_gen_config.sh`, then `config` → `redeploy`. Trigger one forbidden
  DELETE on rpi3, and after the next flush (≤ 15 min) check that
  `audit::deny_batch_count` grew. Then check that the anchored digest equals
  the `sha256` of the last `{"batch":...}` marker in
  `~/sui-runtime-config/state/deny-log.jsonl`, and the SHA-256 recomputed
  from the lines before it.
- [ ] Rollback until phase G: set the value back to `$PKG_V8` (and the flush
  flag back to false).

### G. Arm governance: [!] publisher, one PTB per line
```bash
# create_council(identity AdminCap BY VALUE, &IdentityRegistry,
#                &trust AdminCap (genesis), &mut TrustRegistry, members, k)
sui client call --package $PKG_V9 --module quorum --function create_council \
  --args $ID_ADMIN_CAP $ID_REG $TRUST_ADMIN_CAP $TRUST_REG "[$RPI1,$RPI2,$RPI3]" 2 \
  --gas-budget 50000000                                  # -> COUNCIL (shared)
sui client call --package $PKG_V9 --module quorum --function deposit_policy_cap  --args $COUNCIL $POL_ADMIN_CAP     --gas-budget 20000000
sui client call --package $PKG_V9 --module quorum --function deposit_issuer_cap  --args $COUNCIL $ISSUER_CAP        --gas-budget 20000000
sui client call --package $PKG_V9 --module quorum --function deposit_cluster_cap --args $COUNCIL $CLUSTER_ADMIN_CAP --gas-budget 20000000
```
- [ ] Phase F must be verified first. After this step, any v8-id score write
  aborts with `E_CAP_REVOKED`.
- [ ] This step is **one-way**.
- [ ] `02_bootstrap.sh` can no longer register nodes or mint tokens. From now
  on, onboarding is a proposal.

### H. Verification on the live system
- [ ] Read checks:
  - `quorum::holds_{identity,policy,issuer,cluster}_cap` are all true;
  - `trust::is_governed` is true;
  - `sui client object` on each deposited cap shows it owned by the Council's
    dynamic field.
- [ ] **The review's attack, as a no-gas dry run.** Signing as rpi1,
  `trust::revoke_admin($TRUST_ADMIN_CAP_RPI1, $TRUST_REG, $TRUST_ADMIN_CAP_RPI2)`
  must abort:
  - through `$PKG_V9`: `E_GOVERNED` (8);
  - through `$PKG_V8`: `E_CAP_REVOKED` (5).
- [ ] **First governed action, a live 2-of-3.** Revoke the publisher's genesis
  trust cap. It is not a council member's cap, so it is the last off-cluster
  admin key:
  - rpi1 runs `propose(COUNCIL, TRUST_ADMIN_CAP_RPI1, TRUST_REG, 11,
    <TRUST_ADMIN_CAP as address>, b"", 0,0,0, 86400000, 0x6)`;
  - rpi2 runs `approve`;
  - rpi1 runs `execute_trust`;
  - check that `is_cap_valid(TRUST_ADMIN_CAP)` is false.
- [ ] C2 GRANT, trust writes and failover are unaffected; check them with
  `04_cutover.sh verify`.
- [ ] **F2, live:** in the next failover test, read the cluster right after
  the claim. `ParentPoaKey` must be gone. After the new parent's
  `set_parent_poa`, `ParentPoaOwnerKey` must equal `current_parent`, and
  followers must follow the new PoA without the plugin workaround firing.

### I. Rollback
- **Before G:** config only (phase F).
- **After G:** forward-fix only, through a multisig upgrade. Package versions
  can't be removed, and arming is one-way by design. Rolling back would
  re-create the single-key authority v9 removes.

### What Mouaz / Hamza / the third signer must provide
1. ~~Install CLI `testnet-v1.83.1` in WSL (phase B).~~ Done 2026-11-10.
   Each signer installs it on their own machine (`V9_SIGNERS.md` §1).
2. Three ed25519 public keys (`flag||pk` Base64), one per signer, plus a
   decision on who the third signer is.
3. About 1 SUI of testnet gas for the multisig address, and gas for each
   node's address for governance transactions.
4. Signatures: the publisher for D and G; any two signers for E and every
   later upgrade; rpi1 and rpi2 (on the Pis, with their own keystores) for the
   first governed action in H.

---

## Appendix A: offline compatibility check

Build v8 from `git archive HEAD move` and v9 from the working tree, then run:

```bash
#!/bin/bash
# Every v8 struct (name, abilities, fields) and every v8 public / entry function
# signature must appear unchanged in v9. New modules/structs/functions allowed.
set -u
OLD=$1; NEW=$2; fail=0
sig() {
  sui move disassemble "$1" 2>/dev/null | awk '
    /^(public )?(native )?struct / {s=$0; inS=1; next}
    inS { s=s " " $0; if ($0 ~ /^}/) {gsub(/[ \t]+/," ",s); print "S| " s; inS=0}; next }
    /^(public|entry|public entry) / && /\(/ { line=$0; sub(/\{.*$/,"",line); gsub(/[ \t]+/," ",line); print "F| " line }'
}
for mv in "$OLD"/*.mv; do
  m=$(basename "$mv")
  [ -f "$NEW/$m" ] || { echo "MISSING MODULE $m"; fail=1; continue; }
  sig "$mv" | sort > /tmp/o.sig; sig "$NEW/$m" | sort > /tmp/n.sig
  missing=$(comm -23 /tmp/o.sig /tmp/n.sig)
  [ -n "$missing" ] && { echo "$m:"; echo "$missing" | sed 's/^/  - /'; fail=1; }
done
[ $fail = 0 ] && echo "RESULT: COMPATIBLE" || echo "RESULT: INCOMPATIBLE"
```

`public(friend)` / `public(package)` and private functions are excluded on
purpose: compatible upgrades may change them.

Output on 2026-11-10, after F2:
- no item removed or changed in any module;
- added: `+ failover::cap_cluster`, `+ failover::parent_poa_owner`,
  `+ struct ParentPoaOwnerKey`, `+ trust::is_governed`;
- `NEW MODULE quorum.mv`;
- `RESULT: COMPATIBLE`.
