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
    use sui::dynamic_field as df;

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
    //
    // A7: this was `public fun`, so any external transaction could append a
    // fully-attacker-controlled record (including decision = GRANTED) to the
    // canonical audit trail and emit a matching AccessLogged event. It is now
    // `public(package)`: the only ways in are evaluator::decide_and_log
    // (which requires an unforgeable policy::PolicyReceipt) and
    // evaluator::log_denied_authorized (which requires the AuditAdminCap).
    public(package) fun log(
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

    // ===================================================================
    // v9 (F3): batched DENY records.
    //
    // Since the plugin's free pre-check, a denied request is never submitted,
    // so it leaves no on-chain trace at all (and before that, its abort rolled
    // the audit write back anyway). Recording each DENY on-chain one by one
    // would bring back the gas drain the pre-check closed. Instead a node
    // anchors, at most every DENY_BATCH_MIN_INTERVAL_MS, ONE compact record
    // per window of its local DENY log: the window bounds, the DENY count,
    // the number of distinct originator/resource/op keys, and the SHA-256 of
    // the window's exact log lines. Anyone holding the node's log can
    // recompute the digest, so a later edit to it is detectable, and the
    // count is public.
    //
    // Additive only (new structs, a dynamic field on the trail, new
    // functions), so it ships in the v9 compatible upgrade. Entry is
    // `public(package)` (A7): the only way in is evaluator::log_deny_batch,
    // which needs an IdentityReceipt for a registered IN/MN-CSE and a valid
    // trust AdminCap.
    // ===================================================================
    const E_BAD_DIGEST: u64 = 2;
    const E_EMPTY_BATCH: u64 = 3;
    const E_BAD_WINDOW: u64 = 4;
    const E_BATCH_TOO_SOON: u64 = 5;
    const E_WINDOW_OVERLAP: u64 = 6;

    // Minimum time between two batches from the same node.
    const DENY_BATCH_MIN_INTERVAL_MS: u64 = 300_000;
    // Longest window a single batch may cover.
    const DENY_BATCH_MAX_WINDOW_MS: u64 = 86_400_000;
    // Tolerated node-clock lead over the chain clock for window_end.
    const DENY_BATCH_MAX_SKEW_MS: u64 = 60_000;
    // On-chain ring of the most recent batches (all nodes).
    const DENY_BATCH_RING: u64 = 256;

    public struct DenyBatch has store, copy, drop {
        node:            address,
        window_start_ms: u64,
        window_end_ms:   u64,
        deny_count:      u64,
        distinct_keys:   u64,
        digest:          vector<u8>,
        logged_at_ms:    u64,
    }

    public struct DenyLogKey has copy, drop, store {}
    public struct DenyLog has store {
        next: u64,
        batches: vector<DenyBatch>,
    }

    public struct DenyNodeKey has copy, drop, store { node: address }
    public struct DenyNodeState has store, drop {
        last_logged_ms: u64,
        last_window_end_ms: u64,
    }

    // Canonical event for one anchored DENY window.
    public struct DenialsLogged has copy, drop {
        node:            address,
        window_start_ms: u64,
        window_end_ms:   u64,
        deny_count:      u64,
        distinct_keys:   u64,
        digest:          vector<u8>,
        logged_at_ms:    u64,
    }

    public(package) fun log_deny_batch(
        trail: &mut AuditTrail,
        node: address,
        window_start_ms: u64,
        window_end_ms: u64,
        deny_count: u64,
        distinct_keys: u64,
        digest: vector<u8>,
        clock: &Clock,
    ) {
        let now = clock::timestamp_ms(clock);
        assert!(vector::length(&digest) == 32, E_BAD_DIGEST);
        assert!(deny_count > 0 && distinct_keys > 0 && distinct_keys <= deny_count, E_EMPTY_BATCH);
        assert!(window_start_ms < window_end_ms, E_BAD_WINDOW);
        assert!(window_end_ms - window_start_ms <= DENY_BATCH_MAX_WINDOW_MS, E_BAD_WINDOW);
        assert!(window_end_ms <= now + DENY_BATCH_MAX_SKEW_MS, E_BAD_WINDOW);

        // Per-node rate limit and replay/overlap protection.
        let nk = DenyNodeKey { node };
        if (df::exists_(&trail.id, nk)) {
            let st = df::borrow_mut<DenyNodeKey, DenyNodeState>(&mut trail.id, nk);
            assert!(now >= st.last_logged_ms + DENY_BATCH_MIN_INTERVAL_MS, E_BATCH_TOO_SOON);
            assert!(window_start_ms >= st.last_window_end_ms, E_WINDOW_OVERLAP);
            st.last_logged_ms = now;
            st.last_window_end_ms = window_end_ms;
        } else {
            df::add(&mut trail.id, nk, DenyNodeState { last_logged_ms: now, last_window_end_ms: window_end_ms });
        };

        let b = DenyBatch {
            node, window_start_ms, window_end_ms, deny_count, distinct_keys,
            digest, logged_at_ms: now,
        };
        event::emit(DenialsLogged {
            node, window_start_ms, window_end_ms, deny_count, distinct_keys,
            digest: b.digest, logged_at_ms: now,
        });

        if (!df::exists_(&trail.id, DenyLogKey {})) {
            df::add(&mut trail.id, DenyLogKey {}, DenyLog { next: 0, batches: vector[] });
        };
        let log = df::borrow_mut<DenyLogKey, DenyLog>(&mut trail.id, DenyLogKey {});
        if (vector::length(&log.batches) < DENY_BATCH_RING) {
            vector::push_back(&mut log.batches, b);
        } else {
            let slot = log.next % DENY_BATCH_RING;
            *vector::borrow_mut(&mut log.batches, slot) = b;
        };
        log.next = log.next + 1;
    }

    // Number of DENY batches ever anchored (all nodes).
    public fun deny_batch_count(trail: &AuditTrail): u64 {
        if (!df::exists_(&trail.id, DenyLogKey {})) return 0;
        df::borrow<DenyLogKey, DenyLog>(&trail.id, DenyLogKey {}).next
    }

    // The most recent batch: (node, start, end, count, distinct, digest, logged_at).
    public fun latest_deny_batch(trail: &AuditTrail): (address, u64, u64, u64, u64, vector<u8>, u64) {
        let log = df::borrow<DenyLogKey, DenyLog>(&trail.id, DenyLogKey {});
        let idx = (log.next - 1) % DENY_BATCH_RING;
        let b = vector::borrow(&log.batches, idx);
        (b.node, b.window_start_ms, b.window_end_ms, b.deny_count, b.distinct_keys, b.digest, b.logged_at_ms)
    }

    public fun deny_batch_min_interval_ms(): u64 { DENY_BATCH_MIN_INTERVAL_MS }

    // === Reads ===
    public fun ring_size(trail: &AuditTrail): u64 { trail.ring_size }
    public fun count(trail: &AuditTrail): u64 { trail.next_slot }

    // === Decision constants ===
    public fun decision_granted(): u8 { DECISION_GRANTED }
    public fun decision_denied():  u8 { DECISION_DENIED  }

    #[test_only] public fun init_for_testing(ctx: &mut sui::tx_context::TxContext) { init(ctx) }
}
