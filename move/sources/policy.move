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

    // === Errors ===
    const E_POLICY_MISSING: u64 = 1;
    const E_OP_DENIED:      u64 = 2;
    const E_TRUST_BELOW_MIN: u64 = 3;
    const E_IN_BLACKOUT:    u64 = 4;
    const E_BAD_WINDOW:     u64 = 5;

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
        assert!(table::contains(&registry.policies, resource_id), E_POLICY_MISSING);
        let policy = table::borrow_mut(&mut registry.policies, resource_id);
        vector::push_back(&mut policy.blackouts, BlackoutWindow { start_ms, end_ms });
    }

    public fun clear_blackouts(
        _admin: &PolicyAdminCap,
        registry: &mut PolicyRegistry,
        resource_id: String,
    ) {
        assert!(table::contains(&registry.policies, resource_id), E_POLICY_MISSING);
        let policy = table::borrow_mut(&mut registry.policies, resource_id);
        policy.blackouts = vector[];
    }

    public fun remove_policy(
        _admin: &PolicyAdminCap,
        registry: &mut PolicyRegistry,
        resource_id: String,
    ) {
        assert!(table::contains(&registry.policies, resource_id), E_POLICY_MISSING);
        let _ = table::remove(&mut registry.policies, resource_id);
        event::emit(PolicyRemoved { resource_id });
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
    // Called after steps 1-3 have already passed. Aborts the PTB on any
    // violation, rolling everything back per slide 9.
    //
    // Returns the policy's min_trust value so the evaluator can also
    // log it in the audit step.
    public fun evaluate(
        registry: &PolicyRegistry,
        resource_id: &String,
        requested_op: u8,
        requester_trust: u64,
        clock: &Clock,
    ): u64 {
        assert!(table::contains(&registry.policies, *resource_id), E_POLICY_MISSING);
        let p = table::borrow(&registry.policies, *resource_id);

        assert!(requester_trust >= p.min_trust, E_TRUST_BELOW_MIN);
        assert!((p.allowed_ops_mask & requested_op) == requested_op, E_OP_DENIED);

        let now = clock::timestamp_ms(clock);
        assert!(!in_blackout(p, now), E_IN_BLACKOUT);

        p.min_trust
    }

    // === Reads ===
    public fun has_policy(registry: &PolicyRegistry, resource_id: &String): bool {
        table::contains(&registry.policies, *resource_id)
    }

    public fun min_trust_for(registry: &PolicyRegistry, resource_id: &String): u64 {
        let p = table::borrow(&registry.policies, *resource_id);
        p.min_trust
    }
}
