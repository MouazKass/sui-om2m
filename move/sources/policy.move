// policy.move
//
// PTB step 4 of slide 9: "Policy".
//
// A Policy is a per-resource configuration that the access PTB consults
// after identity, trust, and token checks have passed. Three knobs:
//
//   * min_trust          — lower bound on requester's trust score
//   * allowed_ops_mask   — bitmask of operations permitted on this
//                          resource regardless of what tokens claim
//   * blackout windows   — optional list of [start_ms, end_ms] ranges
//                          during which the resource is off-limits
//                          (e.g. maintenance, off-hours)
//
// Policies live in a shared registry keyed by resource_id (the OM2M URI
// string). The IN-CSE writes them via PolicyAdminCap.

module om2m_access::policy {
    use std::string::String;
    use std::vector;
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::dynamic_field as df;

    use om2m_access::cap_token::{Self, TokenReceipt};
    use om2m_access::trust::{Self, TrustRegistry};
    use om2m_access::identity::{Self, Registry as IdentityRegistry};

    // === Errors ===
    const E_POLICY_MISSING: u64 = 1;
    const E_OP_DENIED:      u64 = 2;
    const E_TRUST_BELOW_MIN: u64 = 3;
    const E_IN_BLACKOUT:    u64 = 4;
    const E_BAD_WINDOW:     u64 = 5;
    // v10: device-bound resources
    const E_DEVICE_BOUND:          u64 = 6; // plain `evaluate` refused: use evaluate_with_device
    const E_DEVICE_NOT_REGISTERED: u64 = 7; // the bound device is not (or no longer) registered
    const E_DEVICE_NOT_END_DEVICE: u64 = 8; // the bound address is registered, but not as a device (role 3)
    const E_READER_NOT_ALLOWED:    u64 = 9; // requester not in the resource's reader list
    const E_NOT_BOUND:             u64 = 10;
    const E_ALREADY_READER:        u64 = 11;
    const E_NOT_READER:            u64 = 12;

    // === Capability ===
    public struct PolicyAdminCap has key, store { id: UID }

    // === Policy ===
    public struct BlackoutWindow has store, copy, drop {
        start_ms: u64,
        end_ms: u64,
    }

    public struct Policy has store, drop {
        min_trust: u64,
        allowed_ops_mask: u8,
        blackouts: vector<BlackoutWindow>,
    }

    // === Registry ===
    public struct PolicyRegistry has key {
        id: UID,
        // resource_id (OM2M URI) -> Policy
        policies: Table<String, Policy>,
    }

    // === v10: device binding ===
    // A resource whose data comes from one IoT device can be BOUND to that
    // device's on-chain identity (identity registry, role 3). The binding is
    // a dynamic field on the PolicyRegistry and it OWNS the resource's
    // Policy: binding moves the Policy out of `policies`, so the v8/v9
    // bytecode of `evaluate` (still callable through the old package ids)
    // finds no policy and aborts E_POLICY_MISSING. Only v10's
    // `evaluate_with_device` can grant a bound resource, and it requires the
    // device to be registered as an end device at decision time, and the
    // requester to be on the reader list when that list is non-empty.
    public struct DeviceBindingKey has copy, drop, store { resource_id: String }

    public struct DeviceBinding has store, drop {
        device: address,
        readers: vector<address>, // empty = any requester that passes the rest of the chain
        policy: Policy,
    }

    public struct DeviceBound has copy, drop { resource_id: String, device: address }
    public struct DeviceUnbound has copy, drop { resource_id: String, device: address }
    public struct ReaderAdded has copy, drop { resource_id: String, reader: address }
    public struct ReaderRemoved has copy, drop { resource_id: String, reader: address }
    public struct DeviceAccessChecked has copy, drop {
        resource_id: String,
        device: address,
        requester: address,
    }

    // === A6: hot-potato receipt (step 4 -> step 5/6) ===
    // No `drop`, `store`, `copy` or `key`. The last link in the chain: the
    // only way to obtain one is to have passed identity, trust, token and
    // policy checks in this very transaction, in order. `trust_score` is the
    // score this module read out of the TrustRegistry itself (A5), so the
    // audit record cannot be seeded with an invented number.
    public struct PolicyReceipt {
        requester: address,
        resource_id: String,
        requested_op: u8,
        trust_score: u64,
        min_trust: u64,
        token_uses: u64,
    }

    // === Events ===
    public struct PolicySet has copy, drop {
        resource_id: String,
        min_trust: u64,
        allowed_ops_mask: u8,
    }

    public struct PolicyRemoved has copy, drop {
        resource_id: String,
    }

    // === Init ===
    fun init(ctx: &mut TxContext) {
        let cap = PolicyAdminCap { id: object::new(ctx) };
        transfer::public_transfer(cap, tx_context::sender(ctx));

        let registry = PolicyRegistry {
            id: object::new(ctx),
            policies: table::new<String, Policy>(ctx),
        };
        transfer::share_object(registry);
    }

    // === Admin ===
    public fun set_policy(
        _admin: &PolicyAdminCap,
        registry: &mut PolicyRegistry,
        resource_id: String,
        min_trust: u64,
        allowed_ops_mask: u8,
    ) {
        // v10: a device-bound resource keeps its Policy inside the binding.
        if (is_device_bound(registry, &resource_id)) {
            let b = df::borrow_mut<DeviceBindingKey, DeviceBinding>(
                &mut registry.id, DeviceBindingKey { resource_id });
            b.policy.min_trust = min_trust;
            b.policy.allowed_ops_mask = allowed_ops_mask;
            event::emit(PolicySet { resource_id, min_trust, allowed_ops_mask });
            return
        };
        // If exists, replace by removing then adding (Move's Table has no
        // upsert primitive).
        if (table::contains(&registry.policies, resource_id)) {
            let _ = table::remove(&mut registry.policies, resource_id);
        };

        let p = Policy {
            min_trust,
            allowed_ops_mask,
            blackouts: vector[],
        };
        table::add(&mut registry.policies, resource_id, p);

        event::emit(PolicySet {
            resource_id,
            min_trust,
            allowed_ops_mask,
        });
    }

    public fun add_blackout(
        _admin: &PolicyAdminCap,
        registry: &mut PolicyRegistry,
        resource_id: String,
        start_ms: u64,
        end_ms: u64,
    ) {
        assert!(start_ms < end_ms, E_BAD_WINDOW);
        let policy = policy_mut(registry, resource_id);
        vector::push_back(&mut policy.blackouts, BlackoutWindow { start_ms, end_ms });
    }

    public fun clear_blackouts(
        _admin: &PolicyAdminCap,
        registry: &mut PolicyRegistry,
        resource_id: String,
    ) {
        let policy = policy_mut(registry, resource_id);
        policy.blackouts = vector[];
    }

    public fun remove_policy(
        _admin: &PolicyAdminCap,
        registry: &mut PolicyRegistry,
        resource_id: String,
    ) {
        // v10: removing the policy of a bound resource removes the binding
        // with it (no policy = no access, as before).
        if (is_device_bound(registry, &resource_id)) {
            let b = df::remove<DeviceBindingKey, DeviceBinding>(
                &mut registry.id, DeviceBindingKey { resource_id });
            event::emit(DeviceUnbound { resource_id, device: b.device });
            event::emit(PolicyRemoved { resource_id });
            return
        };
        assert!(table::contains(&registry.policies, resource_id), E_POLICY_MISSING);
        let _ = table::remove(&mut registry.policies, resource_id);
        event::emit(PolicyRemoved { resource_id });
    }

    // === v10: device binding admin (PolicyAdminCap, held by the council) ===

    /// Bind `resource_id` to an IoT device's on-chain identity. The resource
    /// must already have a policy; it moves into the binding. Re-binding an
    /// already bound resource changes the device and keeps the reader list.
    public fun bind_device(
        _admin: &PolicyAdminCap,
        registry: &mut PolicyRegistry,
        resource_id: String,
        device: address,
    ) {
        if (is_device_bound(registry, &resource_id)) {
            let b = df::borrow_mut<DeviceBindingKey, DeviceBinding>(
                &mut registry.id, DeviceBindingKey { resource_id });
            b.device = device;
        } else {
            assert!(table::contains(&registry.policies, resource_id), E_POLICY_MISSING);
            let policy = table::remove(&mut registry.policies, resource_id);
            df::add(&mut registry.id, DeviceBindingKey { resource_id },
                    DeviceBinding { device, readers: vector[], policy });
        };
        event::emit(DeviceBound { resource_id, device });
    }

    /// Undo a binding: the policy moves back to the plain table, readers are dropped.
    public fun unbind_device(
        _admin: &PolicyAdminCap,
        registry: &mut PolicyRegistry,
        resource_id: String,
    ) {
        assert!(is_device_bound(registry, &resource_id), E_NOT_BOUND);
        let DeviceBinding { device, readers: _, policy } = df::remove<DeviceBindingKey, DeviceBinding>(
            &mut registry.id, DeviceBindingKey { resource_id });
        table::add(&mut registry.policies, resource_id, policy);
        event::emit(DeviceUnbound { resource_id, device });
    }

    public fun add_reader(
        _admin: &PolicyAdminCap,
        registry: &mut PolicyRegistry,
        resource_id: String,
        reader: address,
    ) {
        assert!(is_device_bound(registry, &resource_id), E_NOT_BOUND);
        let b = df::borrow_mut<DeviceBindingKey, DeviceBinding>(
            &mut registry.id, DeviceBindingKey { resource_id });
        assert!(!vector::contains(&b.readers, &reader), E_ALREADY_READER);
        vector::push_back(&mut b.readers, reader);
        event::emit(ReaderAdded { resource_id, reader });
    }

    public fun remove_reader(
        _admin: &PolicyAdminCap,
        registry: &mut PolicyRegistry,
        resource_id: String,
        reader: address,
    ) {
        assert!(is_device_bound(registry, &resource_id), E_NOT_BOUND);
        let b = df::borrow_mut<DeviceBindingKey, DeviceBinding>(
            &mut registry.id, DeviceBindingKey { resource_id });
        let (found, i) = vector::index_of(&b.readers, &reader);
        assert!(found, E_NOT_READER);
        vector::remove(&mut b.readers, i);
        event::emit(ReaderRemoved { resource_id, reader });
    }

    // The Policy of a resource, wherever it lives.
    fun policy_mut(registry: &mut PolicyRegistry, resource_id: String): &mut Policy {
        if (is_device_bound(registry, &resource_id)) {
            let b = df::borrow_mut<DeviceBindingKey, DeviceBinding>(
                &mut registry.id, DeviceBindingKey { resource_id });
            &mut b.policy
        } else {
            assert!(table::contains(&registry.policies, resource_id), E_POLICY_MISSING);
            table::borrow_mut(&mut registry.policies, resource_id)
        }
    }

    // === Internal: blackout check ===
    fun in_blackout(p: &Policy, now_ms: u64): bool {
        let mut i = 0;
        let n = vector::length(&p.blackouts);
        while (i < n) {
            let w = vector::borrow(&p.blackouts, i);
            if (now_ms >= w.start_ms && now_ms < w.end_ms) {
                return true
            };
            i = i + 1;
        };
        false
    }

    // === PTB step 4: Policy ===
    // Called after steps 1-3 have already passed — now provably so, because
    // the only way in is a TokenReceipt that step 3 produced.
    //
    // A5: the old signature took `requester_trust: u64` straight from the
    // caller and compared *that* against min_trust, so any PTB could pass
    // 100 and clear the gate. The score is now read here, inside the
    // function, from the TrustRegistry, for the requester the chain carried
    // forward. There is no trust argument left to forge.
    //
    // A6: consumes the TokenReceipt by value and returns a PolicyReceipt for
    // the final decision/audit step.
    public fun evaluate(
        token_receipt: TokenReceipt,
        registry: &PolicyRegistry,
        trust_reg: &TrustRegistry,
        clock: &Clock,
    ): PolicyReceipt {
        let (requester, resource_id, requested_op, _token_id, token_uses) =
            cap_token::consume_token_receipt(token_receipt);
        // v10: a device-bound resource can only be granted by
        // evaluate_with_device (its Policy lives in the binding anyway, so
        // the table lookup below would abort E_POLICY_MISSING; this makes the
        // reason explicit).
        assert!(!is_device_bound(registry, &resource_id), E_DEVICE_BOUND);
        assert!(table::contains(&registry.policies, resource_id), E_POLICY_MISSING);
        let p = table::borrow(&registry.policies, resource_id);
        check_policy(p, requester, resource_id, requested_op, token_uses, trust_reg, clock)
    }

    // v10: PTB step 4 for every resource. Unbound resource: exactly the
    // checks of `evaluate`. Device-bound resource: the same checks against
    // the binding's Policy, plus, at decision time,
    //   * the bound device is registered in the identity registry
    //     (a council `id-deregister` therefore stops all grants on its data),
    //   * with the end-device role (3), not a middleware node,
    //   * and the requester is on the reader list if the list is non-empty.
    // The identity registry is a singleton created by identity::init, so a
    // caller cannot substitute a registry of its own.
    public fun evaluate_with_device(
        token_receipt: TokenReceipt,
        registry: &PolicyRegistry,
        trust_reg: &TrustRegistry,
        id_reg: &IdentityRegistry,
        clock: &Clock,
    ): PolicyReceipt {
        let (requester, resource_id, requested_op, _token_id, token_uses) =
            cap_token::consume_token_receipt(token_receipt);
        if (!is_device_bound(registry, &resource_id)) {
            assert!(table::contains(&registry.policies, resource_id), E_POLICY_MISSING);
            let p = table::borrow(&registry.policies, resource_id);
            return check_policy(p, requester, resource_id, requested_op, token_uses, trust_reg, clock)
        };
        let b = df::borrow<DeviceBindingKey, DeviceBinding>(
            &registry.id, DeviceBindingKey { resource_id });
        assert!(identity::is_registered(id_reg, b.device), E_DEVICE_NOT_REGISTERED);
        assert!(identity::role_of(id_reg, b.device) == identity::role_ae(), E_DEVICE_NOT_END_DEVICE);
        assert!(vector::is_empty(&b.readers) || vector::contains(&b.readers, &requester),
                E_READER_NOT_ALLOWED);
        event::emit(DeviceAccessChecked { resource_id, device: b.device, requester });
        check_policy(&b.policy, requester, resource_id, requested_op, token_uses, trust_reg, clock)
    }

    // Shared body of steps 4 (A5: the score is read here, never supplied).
    fun check_policy(
        p: &Policy,
        requester: address,
        resource_id: String,
        requested_op: u8,
        token_uses: u64,
        trust_reg: &TrustRegistry,
        clock: &Clock,
    ): PolicyReceipt {
        let trust_score = trust::score_of(trust_reg, requester, clock);
        assert!(trust_score >= p.min_trust, E_TRUST_BELOW_MIN);
        assert!((p.allowed_ops_mask & requested_op) == requested_op, E_OP_DENIED);
        let now = clock::timestamp_ms(clock);
        assert!(!in_blackout(p, now), E_IN_BLACKOUT);
        PolicyReceipt {
            requester,
            resource_id,
            requested_op,
            trust_score,
            min_trust: p.min_trust,
            token_uses,
        }
    }

    // Package-internal unwrap of a PolicyReceipt ->
    // (requester, resource_id, requested_op, trust_score, min_trust, token_uses).
    public(package) fun consume_policy_receipt(
        receipt: PolicyReceipt,
    ): (address, String, u8, u64, u64, u64) {
        let PolicyReceipt {
            requester,
            resource_id,
            requested_op,
            trust_score,
            min_trust,
            token_uses,
        } = receipt;
        (requester, resource_id, requested_op, trust_score, min_trust, token_uses)
    }

    // Read-only peeks (do not consume).
    public fun policy_receipt_requester(receipt: &PolicyReceipt): address { receipt.requester }
    public fun policy_receipt_resource(receipt: &PolicyReceipt): &String { &receipt.resource_id }
    public fun policy_receipt_op(receipt: &PolicyReceipt): u8 { receipt.requested_op }
    public fun policy_receipt_trust(receipt: &PolicyReceipt): u64 { receipt.trust_score }
    public fun policy_receipt_min_trust(receipt: &PolicyReceipt): u64 { receipt.min_trust }
    public fun policy_receipt_token_uses(receipt: &PolicyReceipt): u64 { receipt.token_uses }

    // === Reads ===
    public fun has_policy(registry: &PolicyRegistry, resource_id: &String): bool {
        table::contains(&registry.policies, *resource_id) || is_device_bound(registry, resource_id)
    }

    public fun min_trust_for(registry: &PolicyRegistry, resource_id: &String): u64 {
        if (is_device_bound(registry, resource_id)) {
            let b = df::borrow<DeviceBindingKey, DeviceBinding>(
                &registry.id, DeviceBindingKey { resource_id: *resource_id });
            return b.policy.min_trust
        };
        let p = table::borrow(&registry.policies, *resource_id);
        p.min_trust
    }

    // v10 reads
    public fun is_device_bound(registry: &PolicyRegistry, resource_id: &String): bool {
        df::exists_(&registry.id, DeviceBindingKey { resource_id: *resource_id })
    }

    public fun bound_device(registry: &PolicyRegistry, resource_id: &String): address {
        assert!(is_device_bound(registry, resource_id), E_NOT_BOUND);
        df::borrow<DeviceBindingKey, DeviceBinding>(
            &registry.id, DeviceBindingKey { resource_id: *resource_id }).device
    }

    public fun readers_of(registry: &PolicyRegistry, resource_id: &String): vector<address> {
        assert!(is_device_bound(registry, resource_id), E_NOT_BOUND);
        df::borrow<DeviceBindingKey, DeviceBinding>(
            &registry.id, DeviceBindingKey { resource_id: *resource_id }).readers
    }
    #[test_only] public fun init_for_testing(ctx: &mut sui::tx_context::TxContext) { init(ctx) }
    #[test_only] public fun table_has_policy_for_testing(registry: &PolicyRegistry, resource_id: &String): bool {
        table::contains(&registry.policies, *resource_id)
    }
}
