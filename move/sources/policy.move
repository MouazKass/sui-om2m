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

    use om2m_access::cap_token::{Self, TokenReceipt};
    use om2m_access::trust::{Self, TrustRegistry};

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

        assert!(table::contains(&registry.policies, resource_id), E_POLICY_MISSING);

        // Authoritative trust score: read from the registry, not supplied.
        let trust_score = trust::score_of(trust_reg, requester, clock);

        let p = table::borrow(&registry.policies, resource_id);
        assert!(trust_score >= p.min_trust, E_TRUST_BELOW_MIN);
        assert!((p.allowed_ops_mask & requested_op) == requested_op, E_OP_DENIED);

        let now = clock::timestamp_ms(clock);
        assert!(!in_blackout(p, now), E_IN_BLACKOUT);

        let min_trust = p.min_trust;

        PolicyReceipt {
            requester,
            resource_id,
            requested_op,
            trust_score,
            min_trust,
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
        table::contains(&registry.policies, *resource_id)
    }

    public fun min_trust_for(registry: &PolicyRegistry, resource_id: &String): u64 {
        let p = table::borrow(&registry.policies, *resource_id);
        p.min_trust
    }
    #[test_only] public fun init_for_testing(ctx: &mut sui::tx_context::TxContext) { init(ctx) }
}
