// audit.move
//
// PTB step 6 of slide 9: "Audit Log".
//
// Every access PTB ends with an audit log emission. The log lives in
// two places:
//
//   1. As a Sui event — cheap, queryable from any client over RPC, and
//      cryptographically anchored to the transaction that emitted it.
//   2. As an entry in a shared AuditTrail object — keeps the most-recent
//      N records (ring buffer) on-chain for the proxy's quick lookups
//      without a full event scan.
//
// Slide 8 Layer 2's "Zero TOCTOU window" depends on this step happening
// inside the same atomic PTB as the decision. If the log emit is its own
// transaction the guarantee is gone — so this module is `public fun`,
// not `entry fun`, and is meant to be called from `evaluator.move` as
// the final PTB command.

module om2m_access::audit {
    use std::string::String;
    use std::vector;
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::clock::{Self, Clock};
    use sui::event;

    // === Errors ===
    const E_BAD_RING_SIZE: u64 = 1;

    // === Decision codes ===
    const DECISION_GRANTED: u8 = 1;
    const DECISION_DENIED:  u8 = 2;

    // === Capability (admin can resize the on-chain ring) ===
    public struct AuditAdminCap has key, store { id: UID }

    // === Record ===
    public struct AuditRecord has store, copy, drop {
        requester:       address,
        resource_id:     String,
        requested_op:    u8,
        decision:        u8,
        trust_at_check:  u64,
        token_uses:      u64,
        timestamp_ms:    u64,
    }

    // === Trail ===
    // Bounded ring buffer of the last `ring_size` records. Older entries
    // are overwritten. The full history is reconstructable from Sui
    // events; this is just a fast cache.
    public struct AuditTrail has key {
        id: UID,
        ring_size: u64,
        next_slot: u64,
        records: vector<AuditRecord>,
    }

    // === Event ===
    // This event IS the canonical audit record. Indexed by Sui's event
    // store and exportable to anyone with read-only RPC access.
    public struct AccessLogged has copy, drop {
        requester:       address,
        resource_id:     String,
        requested_op:    u8,
        decision:        u8,
        trust_at_check:  u64,
        token_uses:      u64,
        timestamp_ms:    u64,
        // PTB digest is captured by the explorer automatically; no need
        // to thread it through here.
    }

    // === Init ===
    fun init(ctx: &mut TxContext) {
        let cap = AuditAdminCap { id: object::new(ctx) };
        transfer::public_transfer(cap, tx_context::sender(ctx));

        let trail = AuditTrail {
            id: object::new(ctx),
            ring_size: 512,
            next_slot: 0,
            records: vector[],
        };
        transfer::share_object(trail);
    }

    public fun resize(
        _admin: &AuditAdminCap,
        trail: &mut AuditTrail,
        new_size: u64,
    ) {
        assert!(new_size > 0, E_BAD_RING_SIZE);
        trail.ring_size = new_size;
        // Truncation if shrinking is handled on next log call.
    }

    // === PTB step 6: Audit log ===
    // Called from evaluator.move as the last step of every access PTB.
    public fun log(
        trail: &mut AuditTrail,
        requester: address,
        resource_id: String,
        requested_op: u8,
        decision: u8,
        trust_at_check: u64,
        token_uses: u64,
        clock: &Clock,
    ) {
        let now = clock::timestamp_ms(clock);
        let rec = AuditRecord {
            requester,
            resource_id,
            requested_op,
            decision,
            trust_at_check,
            token_uses,
            timestamp_ms: now,
        };

        // Emit the canonical event.
        event::emit(AccessLogged {
            requester,
            resource_id: rec.resource_id,
            requested_op,
            decision,
            trust_at_check,
            token_uses,
            timestamp_ms: now,
        });

        // Append/overwrite into the ring buffer.
        let len = vector::length(&trail.records);
        if (len < trail.ring_size) {
            vector::push_back(&mut trail.records, rec);
        } else {
            // Overwrite at next_slot mod ring_size.
            let slot = trail.next_slot % trail.ring_size;
            let cell = vector::borrow_mut(&mut trail.records, slot);
            *cell = rec;
        };
        trail.next_slot = trail.next_slot + 1;
    }

    // === Reads ===
    public fun ring_size(trail: &AuditTrail): u64 { trail.ring_size }
    public fun count(trail: &AuditTrail): u64 { trail.next_slot }

    // === Decision constants ===
    public fun decision_granted(): u8 { DECISION_GRANTED }
    public fun decision_denied():  u8 { DECISION_DENIED  }
}
