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
    use std::string::String;
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::dynamic_field as df;
    use sui::vec_set::{Self, VecSet};

    use om2m_access::identity::{Self, IdentityReceipt};

    // === Errors ===
    const E_NOT_FOUND: u64 = 1;
    const E_TRUST_TOO_LOW: u64 = 2;
    const E_ALREADY_EXISTS: u64 = 3;
    const E_SELF_SCORING: u64 = 4;
    // TR7: capability revocation
    const E_CAP_REVOKED: u64 = 5;
    // A12: rate limiting on score writes
    const E_DELTA_TOO_LARGE: u64 = 6;
    const E_RATE_LIMITED: u64 = 7;

    // === Bounds ===
    const MAX_SCORE: u64 = 100;
    const DEFAULT_SCORE: u64 = 50;
    // Per-day decay applied lazily on read. 1 point per 24h since
    // last_update_ms.
    const DECAY_PER_DAY: u64 = 1;
    const MS_PER_DAY: u64 = 86_400_000;

    // === A12: write rate limiting ===
    // A single admin write may move a score by at most MAX_DELTA points, and
    // no entry may be written more often than once per MIN_INTERVAL_MS. Both
    // bounds are enforced against the entry's existing `last_update_ms`
    // field, which every write path already refreshes. Together they cap the
    // damage a compromised (but not yet revoked) AdminCap can do: a score can
    // no longer be driven from 100 to 0 in one transaction, nor ground down
    // by a burst of writes inside a single checkpoint.
    const MAX_DELTA: u64 = 15;
    const MIN_INTERVAL_MS: u64 = 60_000;

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

    // === A6: hot-potato receipt (step 2 -> step 3) ===
    // Same no-abilities contract as identity::IdentityReceipt: no `drop`,
    // `store`, `copy` or `key`. `requester` is NOT re-derived here — it is
    // moved out of the IdentityReceipt that step 1 produced, so the address
    // that cleared identity is provably the address whose trust was scored.
    // `resource_id` enters the chain here and is carried by value from now on.
    public struct TrustReceipt {
        requester: address,
        resource_id: String,
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

    /// Emitted when an AdminCap is permanently destroyed via burn_admin.
    public struct AdminCapBurned has copy, drop {
        cap_id: ID,
    }

    // === Init ===
    fun init(ctx: &mut TxContext) {
        let cap = AdminCap { id: object::new(ctx) };

        let mut registry = TrustRegistry {
            id: object::new(ctx),
            entries: table::new<address, TrustEntry>(ctx),
        };

        // A1/A2/A8: this is a fresh publish, so there are no pre-existing
        // AdminCaps to grandfather in. Seed the validity set with the genesis
        // cap and arm fail-closed enforcement immediately — otherwise every
        // assert_cap_valid call below would be a no-op until someone
        // remembered to run bootstrap_valid_caps.
        let genesis_id = object::id(&cap);
        let set = valid_caps_mut(&mut registry);
        vec_set::insert(set, genesis_id);
        df::add(&mut registry.id, BOOTSTRAPPED_KEY, true);

        transfer::public_transfer(cap, tx_context::sender(ctx));
        transfer::share_object(registry);
    }

    // === Admin operations ===
    // A1: the AdminCap used to be accepted as `_admin` and never checked, so
    // a revoked cap could still create trust entries. It is now validated
    // against the TR7 validity set before anything is written.
    public fun add_node(
        admin: &AdminCap,
        registry: &mut TrustRegistry,
        node_addr: address,
        initial_score: u64,
        clock: &Clock,
    ) {
        assert_cap_valid(admin, registry);
        assert!(!table::contains(&registry.entries, node_addr), E_ALREADY_EXISTS);
        let now = clock::timestamp_ms(clock);
        let s = if (initial_score > MAX_SCORE) MAX_SCORE else initial_score;

        table::add(&mut registry.entries, node_addr, TrustEntry {
            score: s,
            last_update_ms: now,
        });

        event::emit(NodeAdded { node_addr, initial_score: s });
    }

    // === A12: rate-limit guard shared by increase/decrease ===
    // Aborts unless (a) the requested delta is within MAX_DELTA and (b) at
    // least MIN_INTERVAL_MS has elapsed since this entry's last_update_ms.
    // Reuses the existing last_update_ms field — no new state is added.
    fun assert_write_allowed(entry: &TrustEntry, delta: u64, now_ms: u64) {
        assert!(delta <= MAX_DELTA, E_DELTA_TOO_LARGE);
        assert!(now_ms >= entry.last_update_ms + MIN_INTERVAL_MS, E_RATE_LIMITED);
    }

    public(package) fun increase(
        admin: &AdminCap,
        registry: &mut TrustRegistry,
        node_addr: address,
        delta: u64,
        clock: &Clock,
    ) {
        assert_cap_valid(admin, registry);
        assert!(table::contains(&registry.entries, node_addr), E_NOT_FOUND);
        let now = clock::timestamp_ms(clock);
        assert_write_allowed(table::borrow(&registry.entries, node_addr), delta, now);
        let entry = table::borrow_mut(&mut registry.entries, node_addr);
        // Apply the delta to the EFFECTIVE (decayed) score, not the stored one.
        // Stored `score` is only the value as of `last_update_ms`; readers see
        // `decayed()`. Using the raw field here let any write erase all
        // accumulated decay (TR4) and move the effective score by far more than
        // MAX_DELTA in one write (TR8): stored 80 decayed to 20, then
        // increase(1) produced 81 — a +61 jump. Folding decay in first keeps
        // both invariants on the score that is actually used for decisions.
        let old = decayed(entry, now);
        let new_score = if (old + delta > MAX_SCORE) MAX_SCORE else old + delta;
        entry.score = new_score;
        entry.last_update_ms = now;

        event::emit(ScoreChanged {
            node_addr,
            old_score: old,
            new_score,
            reason: 1,
        });
    }

    public(package) fun decrease(
        admin: &AdminCap,
        registry: &mut TrustRegistry,
        node_addr: address,
        delta: u64,
        clock: &Clock,
    ) {
        assert_cap_valid(admin, registry);
        assert!(table::contains(&registry.entries, node_addr), E_NOT_FOUND);
        let now = clock::timestamp_ms(clock);
        assert_write_allowed(table::borrow(&registry.entries, node_addr), delta, now);
        let entry = table::borrow_mut(&mut registry.entries, node_addr);
        // Effective (decayed) score — see the note in `increase`.
        let old = decayed(entry, now);
        let new_score = if (delta >= old) 0 else old - delta;
        entry.score = new_score;
        entry.last_update_ms = now;

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
    //
    // A6: consumes the IdentityReceipt from step 1 by value. The node whose
    // score is read is the one identity::verify authenticated — there is no
    // `node_addr` argument left to forge. Returns a TrustReceipt that step 3
    // must consume in turn.
    public fun require_min(
        identity_receipt: IdentityReceipt,
        registry: &TrustRegistry,
        resource_id: String,
        min_required: u64,
        clock: &Clock,
    ): TrustReceipt {
        let requester = identity::consume_identity_receipt(identity_receipt);
        assert!(table::contains(&registry.entries, requester), E_NOT_FOUND);
        let entry = table::borrow(&registry.entries, requester);
        let now = clock::timestamp_ms(clock);
        let effective = decayed(entry, now);
        assert!(effective >= min_required, E_TRUST_TOO_LOW);
        TrustReceipt { requester, resource_id }
    }

    // Package-internal unwrap of a TrustReceipt -> (requester, resource_id).
    public(package) fun consume_trust_receipt(receipt: TrustReceipt): (address, String) {
        let TrustReceipt { requester, resource_id } = receipt;
        (requester, resource_id)
    }

    // Read-only peeks (do not consume).
    public fun trust_receipt_requester(receipt: &TrustReceipt): address {
        receipt.requester
    }

    public fun trust_receipt_resource(receipt: &TrustReceipt): &String {
        &receipt.resource_id
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
        assert_cap_valid(admin, registry);
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
        assert_cap_valid(admin, registry);
        decrease(admin, registry, node_addr, delta, clock);
    }

    /// A2/A8: the single, authoritative grant path. Mints an AdminCap,
    /// registers its id in the validity set, and transfers it. Private, so
    /// there is exactly one implementation of "mint a cap" in this module.
    ///
    /// The GRANTING cap is validated first: a revoked admin can no longer
    /// launder its lost authority into a freshly minted (and therefore
    /// valid-looking) cap.
    fun mint_and_register(
        admin: &AdminCap,
        registry: &mut TrustRegistry,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert_cap_valid(admin, registry);
        let cap = AdminCap { id: object::new(ctx) };
        let cid = object::id(&cap);
        let set = valid_caps_mut(registry);
        if (!vec_set::contains(set, &cid)) { vec_set::insert(set, cid); };
        transfer::public_transfer(cap, recipient);
    }

    /// Mint an additional AdminCap and transfer it to `recipient`.
    /// Gated by an existing *valid* AdminCap, so only a current authority can
    /// delegate. One cap per CSE node — see scripts/grant-admins.sh.
    ///
    /// A8: this used to be a bare `AdminCap { id: object::new(ctx) }` mint
    /// that never touched the validity set, i.e. a second grant path that
    /// produced caps TR7 could never revoke. It now delegates to
    /// mint_and_register, so both entry points are the same code.
    public entry fun grant_admin(
        admin: &AdminCap,
        registry: &mut TrustRegistry,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        mint_and_register(admin, registry, recipient, ctx);
    }

    // TR7: registry-aware grant. Kept as a distinct name because deploy
    // scripts and tests call it; identical behaviour to grant_admin.
    public entry fun grant_admin_registered(
        admin: &AdminCap,
        registry: &mut TrustRegistry,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        mint_and_register(admin, registry, recipient, ctx);
    }


    // ===================================================================
    // TR7: AdminCap revocation via a per-registry validity set.
    //
    // A VecSet<ID> of valid AdminCap ids is stored as a dynamic field on the
    // TrustRegistry. Enforcement is gated on a "bootstrapped" marker: before
    // it is set the checks are FAIL-OPEN (that existed so a compatible
    // upgrade couldn't brick caps minted by the previous version), after it
    // is set they are FAIL-CLOSED — a cap whose id is not in the set (e.g.
    // one that was revoke_admin'd) can do nothing.
    //
    // v8 is a FRESH publish, so init() now registers the genesis cap and sets
    // the marker in the same transaction. The fail-open window is therefore
    // never observable on a v8 package: every cap-gated function below is
    // fail-closed from genesis.
    // ===================================================================

    // Dynamic field keys (b"..." byte-vector keys).
    const VALID_CAPS_KEY: vector<u8> = b"tr7_valid_caps";
    const BOOTSTRAPPED_KEY: vector<u8> = b"tr7_bootstrapped";

    fun is_bootstrapped(registry: &TrustRegistry): bool {
        df::exists_(&registry.id, BOOTSTRAPPED_KEY)
    }

    fun valid_caps_mut(registry: &mut TrustRegistry): &mut VecSet<ID> {
        if (!df::exists_(&registry.id, VALID_CAPS_KEY)) {
            df::add(&mut registry.id, VALID_CAPS_KEY, vec_set::empty<ID>());
        };
        df::borrow_mut<vector<u8>, VecSet<ID>>(&mut registry.id, VALID_CAPS_KEY)
    }

    fun valid_caps(registry: &TrustRegistry): &VecSet<ID> {
        df::borrow<vector<u8>, VecSet<ID>>(&registry.id, VALID_CAPS_KEY)
    }

    // Enforce cap validity, but only once the registry has been bootstrapped.
    // Before bootstrap (immediately post-upgrade) all caps remain valid so the
    // running cluster is not disrupted.
    fun assert_cap_valid(admin: &AdminCap, registry: &TrustRegistry) {
        if (is_bootstrapped(registry)) {
            let id = object::id(admin);
            assert!(
                df::exists_(&registry.id, VALID_CAPS_KEY) &&
                vec_set::contains(valid_caps(registry), &id),
                E_CAP_REVOKED
            );
        }
    }

    // One-time migration: seed the valid-cap set with the ids of caps that
    // already exist (the original AdminCap + any granted before this upgrade),
    // then mark the registry bootstrapped (arms fail-closed enforcement).
    // Gated by holding a (still-valid, pre-bootstrap) AdminCap.
    public entry fun bootstrap_valid_caps(
        admin: &AdminCap,
        registry: &mut TrustRegistry,
        cap_ids: vector<ID>,
        _ctx: &mut TxContext,
    ) {
        // A2: the calling cap must itself be valid. On a fresh publish init()
        // has already bootstrapped the registry, so this is fail-closed from
        // the first transaction and a revoked cap cannot re-register itself.
        assert_cap_valid(admin, registry);
        let set = valid_caps_mut(registry);
        let mut i = 0;
        let n = std::vector::length(&cap_ids);
        while (i < n) {
            let cid = *std::vector::borrow(&cap_ids, i);
            if (!vec_set::contains(set, &cid)) {
                vec_set::insert(set, cid);
            };
            i = i + 1;
        };
        if (!df::exists_(&registry.id, BOOTSTRAPPED_KEY)) {
            df::add(&mut registry.id, BOOTSTRAPPED_KEY, true);
        };
    }

    // Revoke a specific AdminCap by id: remove it from the valid set. After
    // this, guarded score writes using that cap abort with E_CAP_REVOKED.
    // Gated by holding a valid AdminCap (the caller proves current authority).
    public entry fun revoke_admin(
        admin: &AdminCap,
        registry: &mut TrustRegistry,
        cap_id: ID,
        _ctx: &mut TxContext,
    ) {
        assert_cap_valid(admin, registry);
        let set = valid_caps_mut(registry);
        if (vec_set::contains(set, &cap_id)) {
            vec_set::remove(set, &cap_id);
        };
    }


    // TR7 extension: permanently destroy an AdminCap. Removes it from the
    // validity set if present, then deletes the object (consumed by value),
    // so the cap can never be used or re-registered again. Gated by a valid
    // AdminCap (caller proves current authority). Completes the cap
    // lifecycle: mint -> grant -> revoke -> burn.
    public entry fun burn_admin(
        registry: &mut TrustRegistry,
        to_burn: AdminCap,
        _ctx: &mut TxContext,
    ) {
        // Self-burn: possession of the cap is the authority to destroy it.
        let burn_id = object::id(&to_burn);
        // Only touch the validity set if it already exists; never create it
        // here as a side effect of burning.
        if (df::exists_(&registry.id, VALID_CAPS_KEY)) {
            let set = valid_caps_mut(registry);
            if (vec_set::contains(set, &burn_id)) {
                vec_set::remove(set, &burn_id);
            };
        };
        let AdminCap { id } = to_burn;
        object::delete(id);
        // Auditable record: an authority capability was permanently destroyed.
        event::emit(AdminCapBurned { cap_id: burn_id });
    }

    // Read-only: is a given cap id currently valid? (false also if never
    // registered.) Useful for tests/monitoring.
    public fun is_cap_valid(registry: &TrustRegistry, cap_id: ID): bool {
        is_bootstrapped(registry) &&
        df::exists_(&registry.id, VALID_CAPS_KEY) &&
        vec_set::contains(valid_caps(registry), &cap_id)
    }

    #[test_only] public fun init_for_testing(ctx: &mut sui::tx_context::TxContext) { init(ctx) }
}
