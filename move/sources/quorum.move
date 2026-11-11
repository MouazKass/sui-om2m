// quorum.move
//
// v9: k-of-n governance for every administrative capability (paper
// limitation 2).
//
// Before v9, four kinds of administrative action each needed ONE capability
// held by ONE account:
//
//   * registering / deregistering a middleware node   identity::AdminCap
//   * issuing a capability token                      cap_token::IssuerCap
//   * writing an access-control policy                policy::PolicyAdminCap
//   * granting / revoking a trust admin capability    any valid trust::AdminCap
//     (and seeding a trust entry)
//   * changing a failover cluster's trust gate        failover::ClusterAdminCap
//
// so whoever held (or stole) that one key could act alone. This module moves
// all of them behind a shared Council object:
//
//   1. create_council WRAPS the package's only identity::AdminCap inside the
//      Council and arms trust.move's governed mode (one-way). Because that
//      cap is unique, at most one Council can ever exist per deployment.
//   2. deposit_* wraps the PolicyAdminCap, IssuerCap and ClusterAdminCaps.
//      Once deposited nobody holds them: the only way to use them is a
//      proposal that k members approved.
//   3. Governed trust.move rejects every single-cap administrative path with
//      trust::E_GOVERNED; the same operations exist only as
//      public(package) functions this module calls.
//      A cap revoking ITSELF stays unilateral. Arming also moves trust's
//      cap-validity set to a key only v9+ reads, so the still-callable v8
//      bytecode (old package versions stay live on Sui) fails closed.
//
// Flow: propose (proposer auto-approves) -> approve x (k-1) -> execute_*.
//
//   * Members are registered IN-/MN-CSE middleware nodes. Each proposal or
//     approval must present the member's own trust::AdminCap, and that cap
//     must still be valid. The cap's id is recorded with the approval and
//     re-checked at execution, so a member whose cap the council revokes
//     loses every approval it has already given, even on pending proposals.
//   * Approvals are counted at EXECUTION against the CURRENT member set, so
//     removing a member also removes its pending approvals.
//   * Double approval: one approval per address (E_ALREADY_APPROVED).
//   * Replay: proposal ids come from a monotonic counter and a proposal is
//     deleted when it executes, so it can't be executed twice
//     (E_NO_PROPOSAL) and its id is never reused.
//   * Expiry: every proposal carries expires_ms (TTL <= MAX_TTL_MS). Approving
//     or executing after that aborts (E_EXPIRED). discard_expired lets anyone
//     clean up.
//   * Threshold: 2 <= k and 2k > n (a strict majority), so two disjoint
//     coalitions can never both reach quorum, and k = 1 (one key again) is
//     unrepresentable. Membership and threshold changes are proposals too.
//
// Out of scope here, and why:
//   * Trust SCORE writes (increase/decrease_guarded) stay per-node: they are
//     peer attestation, rate-limited by A12 (paper limitation 1).
//   * cap_token::revoke consumes the token by value, so only its owner can
//     destroy it; tokens are bounded by expiry_ms / max_uses and evolution.
//   * audit::AuditAdminCap is used by the DAS on the hot path
//     (log_denied_authorized). It can only append denial records, and it
//     cannot decide a request.
//   * The package UpgradeCap: an upgrade can replace this module, so the
//     UpgradeCap must sit in a k-of-n multisig address (V9_DESIGN.md).

module om2m_access::quorum {
    use std::string::{Self, String};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::vec_set::{Self, VecSet};
    use sui::vec_map::{Self, VecMap};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::dynamic_object_field as dof;

    use om2m_access::identity::{Self, Registry as IdentityRegistry, AdminCap as IdentityAdminCap};
    use om2m_access::trust::{Self, TrustRegistry, AdminCap as TrustAdminCap};
    use om2m_access::policy::{Self, PolicyRegistry, PolicyAdminCap};
    use om2m_access::cap_token::{Self, IssuerCap};
    use om2m_access::failover::{Self, Cluster, ClusterAdminCap};

    // === Errors ===
    const E_NOT_MEMBER: u64 = 1;
    const E_ALREADY_APPROVED: u64 = 2;
    const E_EXPIRED: u64 = 3;
    const E_NO_QUORUM: u64 = 4;
    const E_NO_PROPOSAL: u64 = 5;
    const E_WRONG_ACTION: u64 = 6;
    const E_BAD_THRESHOLD: u64 = 7;
    const E_NOT_ELIGIBLE: u64 = 8;
    const E_CAP_INVALID: u64 = 9;
    const E_BAD_TTL: u64 = 10;
    const E_ALREADY_MEMBER: u64 = 11;
    const E_WRONG_REGISTRY: u64 = 12;
    const E_CAP_MISSING: u64 = 13;
    const E_CAP_ALREADY_HELD: u64 = 14;
    const E_NOT_EXPIRED: u64 = 15;
    const E_DUPLICATE_MEMBER: u64 = 16;
    const E_WRONG_VERSION: u64 = 17;

    // === Bounds ===
    const MAX_TTL_MS: u64 = 604_800_000; // 7 days
    const MIN_THRESHOLD: u64 = 2;

    // Versioned-object pattern: a later upgrade bumps VERSION and migrates
    // council.version, after which every entry point of THIS bytecode aborts
    // (old package versions stay callable on Sui, so they must be fenced).
    const VERSION: u64 = 1;

    // === Action codes ===
    const ACT_ADD_MEMBER: u8 = 1;            // target
    const ACT_REMOVE_MEMBER: u8 = 2;         // target
    const ACT_SET_THRESHOLD: u8 = 3;         // value = k
    const ACT_TRUST_GRANT_ADMIN: u8 = 10;    // target = recipient
    const ACT_TRUST_REVOKE_ADMIN: u8 = 11;   // target = cap id (as address)
    const ACT_TRUST_ADD_NODE: u8 = 12;       // target, value = initial score
    const ACT_ID_REGISTER: u8 = 20;          // target, text = cse_id, value = role
    const ACT_ID_DEREGISTER: u8 = 21;        // target
    const ACT_POLICY_SET: u8 = 30;           // text = resource, value = min_trust, value2 = ops mask
    const ACT_POLICY_REMOVE: u8 = 31;        // text = resource
    const ACT_POLICY_ADD_BLACKOUT: u8 = 32;  // text = resource, value = start_ms, value2 = end_ms
    const ACT_POLICY_CLEAR_BLACKOUTS: u8 = 33; // text = resource
    // v10: device binding (policy::bind_device & co.)
    const ACT_POLICY_BIND_DEVICE: u8 = 34;   // text = resource, target = device address
    const ACT_POLICY_UNBIND_DEVICE: u8 = 35; // text = resource
    const ACT_POLICY_ADD_READER: u8 = 36;    // text = resource, target = reader address
    const ACT_POLICY_REMOVE_READER: u8 = 37; // text = resource, target = reader address
    const ACT_TOKEN_MINT: u8 = 40;           // target = owner, text = resource, value = expiry_ms, value2 = max_uses, value3 = ops
    const ACT_CLUSTER_SET_GATE: u8 = 50;     // target = cluster address, value = new gate

    // === Wrapped-capability keys (dynamic object fields on the Council) ===
    public struct IdentityCapKey has copy, drop, store {}
    public struct PolicyCapKey has copy, drop, store {}
    public struct IssuerCapKey has copy, drop, store {}
    public struct ClusterCapKey has copy, drop, store { cluster: address }

    // === State ===
    public struct Proposal has store, drop {
        action: u8,
        proposer: address,
        target: address,
        text: String,
        value: u64,
        value2: u64,
        value3: u64,
        // approver address -> id of the trust::AdminCap it presented
        approvals: VecMap<address, ID>,
        created_ms: u64,
        expires_ms: u64,
    }

    public struct Council has key {
        id: UID,
        version: u64,
        members: VecSet<address>,
        threshold: u64,
        next_proposal: u64,
        proposals: Table<u64, Proposal>,
        identity_registry: ID,
        trust_registry: ID,
    }

    // === Events ===
    public struct CouncilCreated has copy, drop { council: ID, members: vector<address>, threshold: u64 }
    public struct CapDeposited has copy, drop { council: ID, kind: u8, cap_id: ID }
    public struct Proposed has copy, drop { council: ID, proposal_id: u64, action: u8, proposer: address, expires_ms: u64 }
    public struct Approved has copy, drop { council: ID, proposal_id: u64, approver: address, approvals: u64 }
    public struct Executed has copy, drop { council: ID, proposal_id: u64, action: u8, executor: address, approvals: u64 }
    public struct Discarded has copy, drop { council: ID, proposal_id: u64 }

    // =================================================================
    //  Setup
    // =================================================================

    /// Create THE council. Consumes the package's only identity::AdminCap
    /// (so this can run once per deployment) and arms trust.move's governed
    /// mode with a valid trust AdminCap.
    public fun create_council(
        identity_cap: IdentityAdminCap,
        identity_reg: &IdentityRegistry,
        trust_cap: &TrustAdminCap,
        trust_reg: &mut TrustRegistry,
        members: vector<address>,
        threshold: u64,
        ctx: &mut TxContext,
    ) {
        let mut set = vec_set::empty<address>();
        let mut i = 0;
        let n = vector::length(&members);
        while (i < n) {
            let m = *vector::borrow(&members, i);
            assert!(!vec_set::contains(&set, &m), E_DUPLICATE_MEMBER);
            assert_eligible(identity_reg, m);
            vec_set::insert(&mut set, m);
            i = i + 1;
        };
        assert_threshold_ok(threshold, n);

        let mut council = Council {
            id: object::new(ctx),
            version: VERSION,
            members: set,
            threshold,
            next_proposal: 0,
            proposals: table::new<u64, Proposal>(ctx),
            identity_registry: object::id(identity_reg),
            trust_registry: object::id(trust_reg),
        };
        let council_id = object::id(&council);
        let icap_id = object::id(&identity_cap);
        dof::add(&mut council.id, IdentityCapKey {}, identity_cap);
        trust::set_governed(trust_cap, trust_reg, council_id);

        event::emit(CouncilCreated { council: council_id, members, threshold });
        event::emit(CapDeposited { council: council_id, kind: 1, cap_id: icap_id });
        transfer::share_object(council);
    }

    /// Hand the PolicyAdminCap to the council. Anyone holding it may do this
    /// (it only gives power away).
    public fun deposit_policy_cap(council: &mut Council, cap: PolicyAdminCap) {
        assert_version(council);
        assert!(!dof::exists_(&council.id, PolicyCapKey {}), E_CAP_ALREADY_HELD);
        let cid = object::id(&cap);
        dof::add(&mut council.id, PolicyCapKey {}, cap);
        event::emit(CapDeposited { council: object::id(council), kind: 2, cap_id: cid });
    }

    public fun deposit_issuer_cap(council: &mut Council, cap: IssuerCap) {
        assert_version(council);
        assert!(!dof::exists_(&council.id, IssuerCapKey {}), E_CAP_ALREADY_HELD);
        let cid = object::id(&cap);
        dof::add(&mut council.id, IssuerCapKey {}, cap);
        event::emit(CapDeposited { council: object::id(council), kind: 3, cap_id: cid });
    }

    public fun deposit_cluster_cap(council: &mut Council, cap: ClusterAdminCap) {
        assert_version(council);
        let key = ClusterCapKey { cluster: failover::cap_cluster(&cap) };
        assert!(!dof::exists_(&council.id, key), E_CAP_ALREADY_HELD);
        let cid = object::id(&cap);
        dof::add(&mut council.id, key, cap);
        event::emit(CapDeposited { council: object::id(council), kind: 4, cap_id: cid });
    }

    // =================================================================
    //  Propose / approve
    // =================================================================

    /// Open a proposal. The proposer must be a member presenting its own
    /// valid trust AdminCap; its approval is recorded immediately. Returns
    /// the proposal id (also emitted in `Proposed`).
    public fun propose(
        council: &mut Council,
        member_cap: &TrustAdminCap,
        trust_reg: &TrustRegistry,
        action: u8,
        target: address,
        text: vector<u8>,
        value: u64,
        value2: u64,
        value3: u64,
        ttl_ms: u64,
        clock: &Clock,
        ctx: &TxContext,
    ): u64 {
        assert_known_action(action);
        assert!(ttl_ms > 0 && ttl_ms <= MAX_TTL_MS, E_BAD_TTL);
        let sender = tx_context::sender(ctx);
        assert_member_with_cap(council, member_cap, trust_reg, sender);

        let now = clock::timestamp_ms(clock);
        let mut approvals = vec_map::empty<address, ID>();
        vec_map::insert(&mut approvals, sender, object::id(member_cap));
        let pid = council.next_proposal;
        council.next_proposal = pid + 1;
        table::add(&mut council.proposals, pid, Proposal {
            action,
            proposer: sender,
            target,
            text: string::utf8(text),
            value,
            value2,
            value3,
            approvals,
            created_ms: now,
            expires_ms: now + ttl_ms,
        });
        event::emit(Proposed { council: object::id(council), proposal_id: pid, action, proposer: sender, expires_ms: now + ttl_ms });
        pid
    }

    public fun approve(
        council: &mut Council,
        proposal_id: u64,
        member_cap: &TrustAdminCap,
        trust_reg: &TrustRegistry,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert_member_with_cap(council, member_cap, trust_reg, sender);
        assert!(table::contains(&council.proposals, proposal_id), E_NO_PROPOSAL);
        let council_id = object::id(council);
        let p = table::borrow_mut(&mut council.proposals, proposal_id);
        assert!(clock::timestamp_ms(clock) < p.expires_ms, E_EXPIRED);
        assert!(!vec_map::contains(&p.approvals, &sender), E_ALREADY_APPROVED);
        vec_map::insert(&mut p.approvals, sender, object::id(member_cap));
        event::emit(Approved { council: council_id, proposal_id, approver: sender, approvals: vec_map::size(&p.approvals) });
    }

    /// Anyone may delete a proposal that has expired.
    public fun discard_expired(council: &mut Council, proposal_id: u64, clock: &Clock) {
        assert!(table::contains(&council.proposals, proposal_id), E_NO_PROPOSAL);
        let p = table::borrow(&council.proposals, proposal_id);
        assert!(clock::timestamp_ms(clock) >= p.expires_ms, E_NOT_EXPIRED);
        let _ = table::remove(&mut council.proposals, proposal_id);
        event::emit(Discarded { council: object::id(council), proposal_id });
    }

    // =================================================================
    //  Execute (one entry point per target object set)
    // =================================================================

    /// ADD_MEMBER / REMOVE_MEMBER / SET_THRESHOLD.
    public fun execute_membership(
        council: &mut Council,
        proposal_id: u64,
        identity_reg: &IdentityRegistry,
        trust_reg: &TrustRegistry,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert!(object::id(identity_reg) == council.identity_registry, E_WRONG_REGISTRY);
        let p = take_ready(council, proposal_id, trust_reg, clock, ctx);
        let n = vec_set::size(&council.members);
        if (p.action == ACT_ADD_MEMBER) {
            assert!(!vec_set::contains(&council.members, &p.target), E_ALREADY_MEMBER);
            assert_eligible(identity_reg, p.target);
            assert_threshold_ok(council.threshold, n + 1);
            vec_set::insert(&mut council.members, p.target);
        } else if (p.action == ACT_REMOVE_MEMBER) {
            assert!(vec_set::contains(&council.members, &p.target), E_NOT_MEMBER);
            assert!(n - 1 >= council.threshold, E_BAD_THRESHOLD);
            vec_set::remove(&mut council.members, &p.target);
        } else if (p.action == ACT_SET_THRESHOLD) {
            assert_threshold_ok(p.value, n);
            council.threshold = p.value;
        } else {
            abort E_WRONG_ACTION
        };
        emit_executed(council, proposal_id, &p, ctx);
    }

    /// TRUST_GRANT_ADMIN / TRUST_REVOKE_ADMIN / TRUST_ADD_NODE.
    public fun execute_trust(
        council: &mut Council,
        proposal_id: u64,
        trust_reg: &mut TrustRegistry,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let p = take_ready(council, proposal_id, trust_reg, clock, ctx);
        let cid = object::id(council);
        if (p.action == ACT_TRUST_GRANT_ADMIN) {
            trust::governed_grant(trust_reg, cid, p.target, ctx);
        } else if (p.action == ACT_TRUST_REVOKE_ADMIN) {
            trust::governed_revoke(trust_reg, cid, object::id_from_address(p.target));
        } else if (p.action == ACT_TRUST_ADD_NODE) {
            trust::governed_add_node(trust_reg, cid, p.target, p.value, clock);
        } else {
            abort E_WRONG_ACTION
        };
        emit_executed(council, proposal_id, &p, ctx);
    }

    /// ID_REGISTER / ID_DEREGISTER, using the wrapped identity::AdminCap.
    public fun execute_identity(
        council: &mut Council,
        proposal_id: u64,
        identity_reg: &mut IdentityRegistry,
        trust_reg: &TrustRegistry,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert!(object::id(identity_reg) == council.identity_registry, E_WRONG_REGISTRY);
        let p = take_ready(council, proposal_id, trust_reg, clock, ctx);
        let cap = dof::borrow<IdentityCapKey, IdentityAdminCap>(&council.id, IdentityCapKey {});
        if (p.action == ACT_ID_REGISTER) {
            identity::register(cap, identity_reg, p.target, p.text, (p.value as u8), clock::timestamp_ms(clock));
        } else if (p.action == ACT_ID_DEREGISTER) {
            // A member must leave the council before it can be deregistered,
            // or the council could keep counting a node the system forgot.
            assert!(!vec_set::contains(&council.members, &p.target), E_ALREADY_MEMBER);
            identity::deregister(cap, identity_reg, p.target);
        } else {
            abort E_WRONG_ACTION
        };
        emit_executed(council, proposal_id, &p, ctx);
    }

    /// POLICY_* using the deposited PolicyAdminCap.
    public fun execute_policy(
        council: &mut Council,
        proposal_id: u64,
        policy_reg: &mut PolicyRegistry,
        trust_reg: &TrustRegistry,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert!(dof::exists_(&council.id, PolicyCapKey {}), E_CAP_MISSING);
        let p = take_ready(council, proposal_id, trust_reg, clock, ctx);
        let cap = dof::borrow<PolicyCapKey, PolicyAdminCap>(&council.id, PolicyCapKey {});
        if (p.action == ACT_POLICY_SET) {
            policy::set_policy(cap, policy_reg, p.text, p.value, (p.value2 as u8));
        } else if (p.action == ACT_POLICY_REMOVE) {
            policy::remove_policy(cap, policy_reg, p.text);
        } else if (p.action == ACT_POLICY_ADD_BLACKOUT) {
            policy::add_blackout(cap, policy_reg, p.text, p.value, p.value2);
        } else if (p.action == ACT_POLICY_CLEAR_BLACKOUTS) {
            policy::clear_blackouts(cap, policy_reg, p.text);
        } else if (p.action == ACT_POLICY_BIND_DEVICE) {
            policy::bind_device(cap, policy_reg, p.text, p.target);
        } else if (p.action == ACT_POLICY_UNBIND_DEVICE) {
            policy::unbind_device(cap, policy_reg, p.text);
        } else if (p.action == ACT_POLICY_ADD_READER) {
            policy::add_reader(cap, policy_reg, p.text, p.target);
        } else if (p.action == ACT_POLICY_REMOVE_READER) {
            policy::remove_reader(cap, policy_reg, p.text, p.target);
        } else {
            abort E_WRONG_ACTION
        };
        emit_executed(council, proposal_id, &p, ctx);
    }

    /// TOKEN_MINT using the deposited IssuerCap.
    public fun execute_mint(
        council: &mut Council,
        proposal_id: u64,
        trust_reg: &TrustRegistry,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(dof::exists_(&council.id, IssuerCapKey {}), E_CAP_MISSING);
        let p = take_ready(council, proposal_id, trust_reg, clock, ctx);
        assert!(p.action == ACT_TOKEN_MINT, E_WRONG_ACTION);
        let cap = dof::borrow<IssuerCapKey, IssuerCap>(&council.id, IssuerCapKey {});
        cap_token::mint(cap, p.target, p.text, (p.value3 as u8), p.value, p.value2, ctx);
        emit_executed(council, proposal_id, &p, ctx);
    }

    /// CLUSTER_SET_GATE using the deposited ClusterAdminCap for that cluster.
    public fun execute_cluster(
        council: &mut Council,
        proposal_id: u64,
        cluster: &mut Cluster,
        trust_reg: &TrustRegistry,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let p = take_ready(council, proposal_id, trust_reg, clock, ctx);
        assert!(p.action == ACT_CLUSTER_SET_GATE, E_WRONG_ACTION);
        assert!(object::id_address(cluster) == p.target, E_WRONG_REGISTRY);
        let key = ClusterCapKey { cluster: p.target };
        assert!(dof::exists_(&council.id, key), E_CAP_MISSING);
        let cap = dof::borrow<ClusterCapKey, ClusterAdminCap>(&council.id, key);
        failover::set_trust_gate(cap, cluster, p.value);
        emit_executed(council, proposal_id, &p, ctx);
    }

    // =================================================================
    //  Internals
    // =================================================================

    /// Remove the proposal (replay protection) and check it is live, was
    /// executed by a member, and has >= threshold approvals that still count:
    /// approver is a current member AND its recorded cap is still valid.
    fun take_ready(
        council: &mut Council,
        proposal_id: u64,
        trust_reg: &TrustRegistry,
        clock: &Clock,
        ctx: &TxContext,
    ): Proposal {
        assert_version(council);
        assert!(object::id(trust_reg) == council.trust_registry, E_WRONG_REGISTRY);
        assert!(vec_set::contains(&council.members, &tx_context::sender(ctx)), E_NOT_MEMBER);
        assert!(table::contains(&council.proposals, proposal_id), E_NO_PROPOSAL);
        let p = table::remove(&mut council.proposals, proposal_id);
        assert!(clock::timestamp_ms(clock) < p.expires_ms, E_EXPIRED);
        assert!(count_valid(council, &p, trust_reg) >= council.threshold, E_NO_QUORUM);
        p
    }

    fun count_valid(council: &Council, p: &Proposal, trust_reg: &TrustRegistry): u64 {
        let (who, caps) = vec_map::into_keys_values(*&p.approvals);
        let mut i = 0;
        let mut c = 0;
        let n = vector::length(&who);
        while (i < n) {
            if (vec_set::contains(&council.members, vector::borrow(&who, i))
                && trust::is_cap_valid(trust_reg, *vector::borrow(&caps, i))) {
                c = c + 1;
            };
            i = i + 1;
        };
        c
    }

    fun assert_member_with_cap(council: &Council, cap: &TrustAdminCap, trust_reg: &TrustRegistry, who: address) {
        assert_version(council);
        assert!(object::id(trust_reg) == council.trust_registry, E_WRONG_REGISTRY);
        assert!(vec_set::contains(&council.members, &who), E_NOT_MEMBER);
        assert!(trust::is_cap_valid(trust_reg, object::id(cap)), E_CAP_INVALID);
    }

    fun assert_version(council: &Council) {
        assert!(council.version == VERSION, E_WRONG_VERSION);
    }

    fun assert_eligible(identity_reg: &IdentityRegistry, who: address) {
        assert!(identity::is_registered(identity_reg, who), E_NOT_ELIGIBLE);
        let role = identity::role_of(identity_reg, who);
        assert!(role == identity::role_in_cse() || role == identity::role_mn_cse(), E_NOT_ELIGIBLE);
    }

    // 2 <= k <= n and k is a strict majority of n.
    fun assert_threshold_ok(k: u64, n: u64) {
        assert!(k >= MIN_THRESHOLD && k <= n && 2 * k > n, E_BAD_THRESHOLD);
    }

    fun assert_known_action(a: u8) {
        assert!(
            a == ACT_ADD_MEMBER || a == ACT_REMOVE_MEMBER || a == ACT_SET_THRESHOLD
            || a == ACT_TRUST_GRANT_ADMIN || a == ACT_TRUST_REVOKE_ADMIN || a == ACT_TRUST_ADD_NODE
            || a == ACT_ID_REGISTER || a == ACT_ID_DEREGISTER
            || a == ACT_POLICY_SET || a == ACT_POLICY_REMOVE
            || a == ACT_POLICY_ADD_BLACKOUT || a == ACT_POLICY_CLEAR_BLACKOUTS
            || a == ACT_POLICY_BIND_DEVICE || a == ACT_POLICY_UNBIND_DEVICE
            || a == ACT_POLICY_ADD_READER || a == ACT_POLICY_REMOVE_READER
            || a == ACT_TOKEN_MINT || a == ACT_CLUSTER_SET_GATE,
            E_WRONG_ACTION
        );
    }

    fun emit_executed(council: &Council, proposal_id: u64, p: &Proposal, ctx: &TxContext) {
        event::emit(Executed {
            council: object::id(council),
            proposal_id,
            action: p.action,
            executor: tx_context::sender(ctx),
            approvals: vec_map::size(&p.approvals),
        });
    }

    // === Reads ===
    public fun threshold(council: &Council): u64 { council.threshold }
    public fun version(council: &Council): u64 { council.version }
    public fun is_member(council: &Council, who: address): bool { vec_set::contains(&council.members, &who) }
    public fun member_count(council: &Council): u64 { vec_set::size(&council.members) }
    public fun has_proposal(council: &Council, proposal_id: u64): bool { table::contains(&council.proposals, proposal_id) }
    public fun approval_count(council: &Council, proposal_id: u64): u64 {
        vec_map::size(&table::borrow(&council.proposals, proposal_id).approvals)
    }
    public fun holds_identity_cap(council: &Council): bool { dof::exists_(&council.id, IdentityCapKey {}) }
    public fun holds_policy_cap(council: &Council): bool { dof::exists_(&council.id, PolicyCapKey {}) }
    public fun holds_issuer_cap(council: &Council): bool { dof::exists_(&council.id, IssuerCapKey {}) }
    public fun holds_cluster_cap(council: &Council, cluster: address): bool { dof::exists_(&council.id, ClusterCapKey { cluster }) }

    // Action-code getters for clients and tests.
    public fun act_add_member(): u8 { ACT_ADD_MEMBER }
    public fun act_remove_member(): u8 { ACT_REMOVE_MEMBER }
    public fun act_set_threshold(): u8 { ACT_SET_THRESHOLD }
    public fun act_trust_grant_admin(): u8 { ACT_TRUST_GRANT_ADMIN }
    public fun act_trust_revoke_admin(): u8 { ACT_TRUST_REVOKE_ADMIN }
    public fun act_trust_add_node(): u8 { ACT_TRUST_ADD_NODE }
    public fun act_id_register(): u8 { ACT_ID_REGISTER }
    public fun act_id_deregister(): u8 { ACT_ID_DEREGISTER }
    public fun act_policy_set(): u8 { ACT_POLICY_SET }
    public fun act_policy_remove(): u8 { ACT_POLICY_REMOVE }
    public fun act_policy_add_blackout(): u8 { ACT_POLICY_ADD_BLACKOUT }
    public fun act_policy_clear_blackouts(): u8 { ACT_POLICY_CLEAR_BLACKOUTS }
    public fun act_token_mint(): u8 { ACT_TOKEN_MINT }
    public fun act_policy_bind_device(): u8 { ACT_POLICY_BIND_DEVICE }
    public fun act_policy_unbind_device(): u8 { ACT_POLICY_UNBIND_DEVICE }
    public fun act_policy_add_reader(): u8 { ACT_POLICY_ADD_READER }
    public fun act_policy_remove_reader(): u8 { ACT_POLICY_REMOVE_READER }
    public fun act_cluster_set_gate(): u8 { ACT_CLUSTER_SET_GATE }
}
