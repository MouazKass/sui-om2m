// trust.move
//
// PTB step 2 of slide 9's atomic 6-step evaluation: "Trust Score".
// Also read by parent_failover.move to gate takeover claims.
//
// Trust is a u64 score in [0, MAX_SCORE]. Each registered node has one
// score. The IN-CSE bumps or penalises scores based on observed behaviour
// (handled off-chain by the proxy and submitted via tx). Scores also
// decay linearly with time so stale-but-untrusted nodes don't keep their
// reputation forever.
//
// During the 6-step PTB, step 2 reads the score and aborts the whole
// transaction if it's below the resource's required threshold. The
// threshold itself lives in policy.move.

module om2m_access::trust {
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;

    // === Errors ===
    const E_NOT_FOUND: u64 = 1;
    const E_TRUST_TOO_LOW: u64 = 2;
    const E_ALREADY_EXISTS: u64 = 3;
    const E_SELF_SCORING: u64 = 4;

    // === Bounds ===
    const MAX_SCORE: u64 = 100;
    const DEFAULT_SCORE: u64 = 50;
    // Per-day decay applied lazily on read. 1 point per 24h since
    // last_update_ms.
    const DECAY_PER_DAY: u64 = 1;
    const MS_PER_DAY: u64 = 86_400_000;

    // === Capabilities ===
    public struct AdminCap has key, store { id: UID }

    // === Entry ===
    public struct TrustEntry has store, drop {
        score: u64,
        last_update_ms: u64,
    }

    // === Registry ===
    public struct TrustRegistry has key {
        id: UID,
        entries: Table<address, TrustEntry>,
    }

    // === Events ===
    public struct ScoreChanged has copy, drop {
        node_addr: address,
        old_score: u64,
        new_score: u64,
        reason: u8, // 1 = increase, 2 = decrease, 3 = decay-applied
    }

    public struct NodeAdded has copy, drop {
        node_addr: address,
        initial_score: u64,
    }

    // === Init ===
    fun init(ctx: &mut TxContext) {
        let cap = AdminCap { id: object::new(ctx) };
        transfer::public_transfer(cap, tx_context::sender(ctx));

        let registry = TrustRegistry {
            id: object::new(ctx),
            entries: table::new<address, TrustEntry>(ctx),
        };
        transfer::share_object(registry);
    }

    // === Admin operations ===
    public fun add_node(
        _admin: &AdminCap,
        registry: &mut TrustRegistry,
        node_addr: address,
        initial_score: u64,
        clock: &Clock,
    ) {
        assert!(!table::contains(&registry.entries, node_addr), E_ALREADY_EXISTS);
        let now = clock::timestamp_ms(clock);
        let s = if (initial_score > MAX_SCORE) MAX_SCORE else initial_score;

        table::add(&mut registry.entries, node_addr, TrustEntry {
            score: s,
            last_update_ms: now,
        });

        event::emit(NodeAdded { node_addr, initial_score: s });
    }

    public fun increase(
        _admin: &AdminCap,
        registry: &mut TrustRegistry,
        node_addr: address,
        delta: u64,
        clock: &Clock,
    ) {
        let entry = table::borrow_mut(&mut registry.entries, node_addr);
        let old = entry.score;
        let new_score = if (old + delta > MAX_SCORE) MAX_SCORE else old + delta;
        entry.score = new_score;
        entry.last_update_ms = clock::timestamp_ms(clock);

        event::emit(ScoreChanged {
            node_addr,
            old_score: old,
            new_score,
            reason: 1,
        });
    }

    public fun decrease(
        _admin: &AdminCap,
        registry: &mut TrustRegistry,
        node_addr: address,
        delta: u64,
        clock: &Clock,
    ) {
        let entry = table::borrow_mut(&mut registry.entries, node_addr);
        let old = entry.score;
        let new_score = if (delta >= old) 0 else old - delta;
        entry.score = new_score;
        entry.last_update_ms = clock::timestamp_ms(clock);

        event::emit(ScoreChanged {
            node_addr,
            old_score: old,
            new_score,
            reason: 2,
        });
    }

    // === Decay helper ===
    // Lazy decay: computes what the score *would* be right now, given the
    // time since last update, without mutating state. PTB step 2 uses
    // this for the read path.
    fun decayed(entry: &TrustEntry, now_ms: u64): u64 {
        if (now_ms <= entry.last_update_ms) {
            return entry.score
        };
        let elapsed = now_ms - entry.last_update_ms;
        let days = elapsed / MS_PER_DAY;
        let penalty = days * DECAY_PER_DAY;
        if (penalty >= entry.score) 0 else entry.score - penalty
    }

    // === PTB step 2: Trust Score ===
    // Aborts the PTB if effective trust < min_required.
    public fun require_min(
        registry: &TrustRegistry,
        node_addr: address,
        min_required: u64,
        clock: &Clock,
    ): u64 {
        assert!(table::contains(&registry.entries, node_addr), E_NOT_FOUND);
        let entry = table::borrow(&registry.entries, node_addr);
        let now = clock::timestamp_ms(clock);
        let effective = decayed(entry, now);
        assert!(effective >= min_required, E_TRUST_TOO_LOW);
        effective
    }

    // === Reads ===
    public fun score_of(registry: &TrustRegistry, node_addr: address, clock: &Clock): u64 {
        if (!table::contains(&registry.entries, node_addr)) return 0;
        let entry = table::borrow(&registry.entries, node_addr);
        let now = clock::timestamp_ms(clock);
        decayed(entry, now)
    }

    public fun has_node(registry: &TrustRegistry, node_addr: address): bool {
        table::contains(&registry.entries, node_addr)
    }

    public fun max_score(): u64 { MAX_SCORE }
    public fun default_score(): u64 { DEFAULT_SCORE }

    /// Hardened increase: enforces on-chain that the transaction signer is not
    /// scoring itself (assume-breach: nodes never self-attest). Delegates to the
    /// original `increase` once the self-scoring guard passes.
    public fun increase_guarded(
        admin: &AdminCap,
        registry: &mut TrustRegistry,
        node_addr: address,
        delta: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) != node_addr, E_SELF_SCORING);
        increase(admin, registry, node_addr, delta, clock);
    }

    /// Hardened decrease: same self-scoring guard as `increase_guarded`.
    public fun decrease_guarded(
        admin: &AdminCap,
        registry: &mut TrustRegistry,
        node_addr: address,
        delta: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) != node_addr, E_SELF_SCORING);
        decrease(admin, registry, node_addr, delta, clock);
    }

    /// Mint an additional AdminCap and transfer it to `recipient`.
    /// Gated by an existing AdminCap, so only a current authority can delegate.
    /// One cap per CSE node — see scripts/grant-admins.sh.
    public entry fun grant_admin(
        _admin: &AdminCap,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        let cap = AdminCap { id: object::new(ctx) };
        transfer::public_transfer(cap, recipient);
    }


    #[test_only] public fun init_for_testing(ctx: &mut sui::tx_context::TxContext) { init(ctx) }
}
