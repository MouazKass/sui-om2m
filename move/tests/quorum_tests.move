// quorum_tests.move
//
// v9: offline proof that k-of-n governance (quorum.move) closes paper
// limitation 2, plus the attacks it must reject.
//
// Testbed shape: three registered MN-CSE members (N1, N2, N3), each holding
// its own trust::AdminCap, threshold k = 2. ADMIN is the publisher; it
// creates the council (giving up the identity AdminCap) and deposits the
// PolicyAdminCap, IssuerCap and ClusterAdminCap.
//
//   quorum error codes: E_NOT_MEMBER 1, E_ALREADY_APPROVED 2, E_EXPIRED 3,
//     E_NO_QUORUM 4, E_NO_PROPOSAL 5, E_WRONG_ACTION 6, E_BAD_THRESHOLD 7,
//     E_NOT_ELIGIBLE 8, E_CAP_INVALID 9, E_BAD_TTL 10, E_ALREADY_MEMBER 11,
//     E_DUPLICATE_MEMBER 16
//   trust error codes:  E_GOVERNED 8
//
// Run with:  sui move test

#[test_only]
module om2m_access::quorum_tests {
    use std::string;
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};
    use sui::object::{Self, ID};

    use om2m_access::identity::{Self, Registry as IdentityRegistry, AdminCap as IdentityAdminCap};
    use om2m_access::trust::{Self, TrustRegistry, AdminCap};
    use om2m_access::policy::{Self, PolicyRegistry, PolicyAdminCap};
    use om2m_access::cap_token::{Self, IssuerCap, CapToken};
    use om2m_access::failover::{Self, Cluster, ClusterAdminCap};
    use om2m_access::quorum::{Self, Council};

    const ADMIN: address = @0xA11CE;
    const N1: address = @0x1;
    const N2: address = @0x2;
    const N3: address = @0x3;
    const N4: address = @0x4;
    const N5: address = @0x5;
    const SENSOR: address = @0xAE;       // registered, but an AE: not eligible
    const OUTSIDER: address = @0xBAD;    // not registered at all
    const NEWNODE: address = @0x99;

    const T0: u64 = 1_000_000;
    const TTL: u64 = 3_600_000;

    // ------------------------------------------------------------------
    //  Fixture
    // ------------------------------------------------------------------

    fun register(sc: &mut Scenario, who: address, role: u8) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<IdentityAdminCap>(sc);
        let mut reg = ts::take_shared<IdentityRegistry>(sc);
        identity::register(&cap, &mut reg, who, string::utf8(b"cse"), role, 0);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    fun grant_trust_cap(sc: &mut Scenario, to: address) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let mut reg = ts::take_shared<TrustRegistry>(sc);
        trust::grant_admin_registered(&cap, &mut reg, to, ts::ctx(sc));
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    fun create_council_with(sc: &mut Scenario, members: vector<address>, k: u64) {
        ts::next_tx(sc, ADMIN);
        let icap = ts::take_from_sender<IdentityAdminCap>(sc);
        let tcap = ts::take_from_sender<AdminCap>(sc);
        let ireg = ts::take_shared<IdentityRegistry>(sc);
        let mut treg = ts::take_shared<TrustRegistry>(sc);
        quorum::create_council(icap, &ireg, &tcap, &mut treg, members, k, ts::ctx(sc));
        ts::return_shared(ireg);
        ts::return_shared(treg);
        ts::return_to_sender(sc, tcap);
    }

    /// Everything up to (not including) council creation.
    fun base(): (Scenario, Clock) {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut sc);
            identity::init_for_testing(ctx);
            trust::init_for_testing(ctx);
            policy::init_for_testing(ctx);
            cap_token::init_for_testing(ctx);
        };
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, T0);
        register(&mut sc, N1, identity::role_mn_cse());
        register(&mut sc, N2, identity::role_mn_cse());
        register(&mut sc, N3, identity::role_mn_cse());
        register(&mut sc, N4, identity::role_mn_cse());
        register(&mut sc, N5, identity::role_mn_cse());
        register(&mut sc, SENSOR, identity::role_ae());
        grant_trust_cap(&mut sc, N1);
        grant_trust_cap(&mut sc, N2);
        grant_trust_cap(&mut sc, N3);
        grant_trust_cap(&mut sc, N4);
        grant_trust_cap(&mut sc, N5);
        ts::next_tx(&mut sc, ADMIN);
        failover::create_cluster(b"EE_5", N1, 50, 60_000, &clk, ts::ctx(&mut sc));
        (sc, clk)
    }

    /// Council {N1,N2,N3}, k = 2, with every admin cap handed over.
    fun setup(): (Scenario, Clock) {
        let (mut sc, clk) = base();
        create_council_with(&mut sc, vector[N1, N2, N3], 2);
        ts::next_tx(&mut sc, ADMIN);
        let mut council = ts::take_shared<Council>(&sc);
        quorum::deposit_policy_cap(&mut council, ts::take_from_sender<PolicyAdminCap>(&sc));
        quorum::deposit_issuer_cap(&mut council, ts::take_from_sender<IssuerCap>(&sc));
        quorum::deposit_cluster_cap(&mut council, ts::take_from_sender<ClusterAdminCap>(&sc));
        ts::return_shared(council);
        (sc, clk)
    }

    /// The 5-node testbed (2026-11-10: rpi4 and rpi5 added): council
    /// {N1..N5}, k = 3 (strict majority), every admin cap handed over.
    fun setup5(): (Scenario, Clock) {
        let (mut sc, clk) = base();
        create_council_with(&mut sc, vector[N1, N2, N3, N4, N5], 3);
        ts::next_tx(&mut sc, ADMIN);
        let mut council = ts::take_shared<Council>(&sc);
        quorum::deposit_policy_cap(&mut council, ts::take_from_sender<PolicyAdminCap>(&sc));
        quorum::deposit_issuer_cap(&mut council, ts::take_from_sender<IssuerCap>(&sc));
        quorum::deposit_cluster_cap(&mut council, ts::take_from_sender<ClusterAdminCap>(&sc));
        ts::return_shared(council);
        (sc, clk)
    }

    fun finish(sc: Scenario, clk: Clock) {
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    fun cap_id_of(sc: &mut Scenario, who: address): ID {
        ts::next_tx(sc, who);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let id = object::id(&cap);
        ts::return_to_sender(sc, cap);
        id
    }

    fun propose_as(
        sc: &mut Scenario, who: address, action: u8, target: address,
        text: vector<u8>, v: u64, v2: u64, v3: u64, ttl: u64, clk: &Clock,
    ): u64 {
        ts::next_tx(sc, who);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let mut council = ts::take_shared<Council>(sc);
        let treg = ts::take_shared<TrustRegistry>(sc);
        let pid = quorum::propose(&mut council, &cap, &treg, action, target, text, v, v2, v3, ttl, clk, ts::ctx(sc));
        ts::return_shared(treg);
        ts::return_shared(council);
        ts::return_to_sender(sc, cap);
        pid
    }

    fun approve_as(sc: &mut Scenario, who: address, pid: u64, clk: &Clock) {
        ts::next_tx(sc, who);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let mut council = ts::take_shared<Council>(sc);
        let treg = ts::take_shared<TrustRegistry>(sc);
        quorum::approve(&mut council, pid, &cap, &treg, clk, ts::ctx(sc));
        ts::return_shared(treg);
        ts::return_shared(council);
        ts::return_to_sender(sc, cap);
    }

    fun exec_trust_as(sc: &mut Scenario, who: address, pid: u64, clk: &Clock) {
        ts::next_tx(sc, who);
        let mut council = ts::take_shared<Council>(sc);
        let mut treg = ts::take_shared<TrustRegistry>(sc);
        quorum::execute_trust(&mut council, pid, &mut treg, clk, ts::ctx(sc));
        ts::return_shared(treg);
        ts::return_shared(council);
    }

    fun exec_membership_as(sc: &mut Scenario, who: address, pid: u64, clk: &Clock) {
        ts::next_tx(sc, who);
        let mut council = ts::take_shared<Council>(sc);
        let ireg = ts::take_shared<IdentityRegistry>(sc);
        let treg = ts::take_shared<TrustRegistry>(sc);
        quorum::execute_membership(&mut council, pid, &ireg, &treg, clk, ts::ctx(sc));
        ts::return_shared(treg);
        ts::return_shared(ireg);
        ts::return_shared(council);
    }

    fun exec_identity_as(sc: &mut Scenario, who: address, pid: u64, clk: &Clock) {
        ts::next_tx(sc, who);
        let mut council = ts::take_shared<Council>(sc);
        let mut ireg = ts::take_shared<IdentityRegistry>(sc);
        let treg = ts::take_shared<TrustRegistry>(sc);
        quorum::execute_identity(&mut council, pid, &mut ireg, &treg, clk, ts::ctx(sc));
        ts::return_shared(treg);
        ts::return_shared(ireg);
        ts::return_shared(council);
    }

    /// N1 proposes revoking `victim`'s cap, N2 approves, N1 executes.
    fun council_revokes(sc: &mut Scenario, victim: address, clk: &Clock) {
        let vid = cap_id_of(sc, victim);
        let pid = propose_as(sc, N1, quorum::act_trust_revoke_admin(), object::id_to_address(&vid), b"", 0, 0, 0, TTL, clk);
        approve_as(sc, N2, pid, clk);
        exec_trust_as(sc, N1, pid, clk);
    }

    // ==================================================================
    //  Positive controls
    // ==================================================================

    #[test]
    fun create_council_wraps_caps_and_arms_governance() {
        let (mut sc, clk) = setup();
        ts::next_tx(&mut sc, ADMIN);
        {
            let council = ts::take_shared<Council>(&sc);
            let treg = ts::take_shared<TrustRegistry>(&sc);
            assert!(trust::is_governed(&treg), 0);
            assert!(quorum::threshold(&council) == 2, 1);
            assert!(quorum::member_count(&council) == 3, 2);
            assert!(quorum::holds_identity_cap(&council), 3);
            assert!(quorum::holds_policy_cap(&council), 4);
            assert!(quorum::holds_issuer_cap(&council), 5);
            // The publisher no longer holds any of them.
            assert!(!ts::has_most_recent_for_sender<IdentityAdminCap>(&sc), 6);
            assert!(!ts::has_most_recent_for_sender<PolicyAdminCap>(&sc), 7);
            assert!(!ts::has_most_recent_for_sender<IssuerCap>(&sc), 8);
            ts::return_shared(treg);
            ts::return_shared(council);
        };
        finish(sc, clk);
    }

    #[test]
    fun revoke_admin_with_two_of_three() {
        let (mut sc, clk) = setup();
        let vid = cap_id_of(&mut sc, N3);
        council_revokes(&mut sc, N3, &clk);
        ts::next_tx(&mut sc, ADMIN);
        let treg = ts::take_shared<TrustRegistry>(&sc);
        assert!(!trust::is_cap_valid(&treg, vid), 0);
        ts::return_shared(treg);
        finish(sc, clk);
    }

    #[test]
    fun grant_admin_with_two_of_three() {
        let (mut sc, clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_trust_grant_admin(), NEWNODE, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N3, pid, &clk);
        exec_trust_as(&mut sc, N2, pid, &clk);
        let nid = cap_id_of(&mut sc, NEWNODE);
        let treg = ts::take_shared<TrustRegistry>(&sc);
        assert!(trust::is_cap_valid(&treg, nid), 0);
        ts::return_shared(treg);
        finish(sc, clk);
    }

    #[test]
    fun onboard_node_identity_then_trust() {
        let (mut sc, clk) = setup();
        let p1 = propose_as(&mut sc, N1, quorum::act_id_register(), NEWNODE, b"mn-cse-new", 2, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, p1, &clk);
        exec_identity_as(&mut sc, N1, p1, &clk);
        let p2 = propose_as(&mut sc, N2, quorum::act_trust_add_node(), NEWNODE, b"", 60, 0, 0, TTL, &clk);
        approve_as(&mut sc, N3, p2, &clk);
        exec_trust_as(&mut sc, N3, p2, &clk);
        ts::next_tx(&mut sc, ADMIN);
        let ireg = ts::take_shared<IdentityRegistry>(&sc);
        let treg = ts::take_shared<TrustRegistry>(&sc);
        assert!(identity::is_registered(&ireg, NEWNODE), 0);
        assert!(identity::role_of(&ireg, NEWNODE) == identity::role_mn_cse(), 1);
        assert!(trust::score_of(&treg, NEWNODE, &clk) == 60, 2);
        ts::return_shared(treg);
        ts::return_shared(ireg);
        finish(sc, clk);
    }

    #[test]
    fun deregister_via_council() {
        let (mut sc, clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_id_deregister(), N4, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, pid, &clk);
        exec_identity_as(&mut sc, N1, pid, &clk);
        ts::next_tx(&mut sc, ADMIN);
        let ireg = ts::take_shared<IdentityRegistry>(&sc);
        assert!(!identity::is_registered(&ireg, N4), 0);
        ts::return_shared(ireg);
        finish(sc, clk);
    }

    #[test]
    fun policy_write_via_council() {
        let (mut sc, clk) = setup();
        let pid = propose_as(&mut sc, N2, quorum::act_policy_set(), @0x0, b"sui-protected-ae", 70, 0x3, 0, TTL, &clk);
        approve_as(&mut sc, N1, pid, &clk);
        ts::next_tx(&mut sc, N1);
        {
            let mut council = ts::take_shared<Council>(&sc);
            let mut preg = ts::take_shared<PolicyRegistry>(&sc);
            let treg = ts::take_shared<TrustRegistry>(&sc);
            quorum::execute_policy(&mut council, pid, &mut preg, &treg, &clk, ts::ctx(&mut sc));
            let r = string::utf8(b"sui-protected-ae");
            assert!(policy::has_policy(&preg, &r), 0);
            assert!(policy::min_trust_for(&preg, &r) == 70, 1);
            ts::return_shared(treg);
            ts::return_shared(preg);
            ts::return_shared(council);
        };
        finish(sc, clk);
    }

    fun exec_policy_as(sc: &mut Scenario, who: address, pid: u64, clk: &Clock) {
        ts::next_tx(sc, who);
        let mut council = ts::take_shared<Council>(sc);
        let mut preg = ts::take_shared<PolicyRegistry>(sc);
        let treg = ts::take_shared<TrustRegistry>(sc);
        quorum::execute_policy(&mut council, pid, &mut preg, &treg, clk, ts::ctx(sc));
        ts::return_shared(treg);
        ts::return_shared(preg);
        ts::return_shared(council);
    }

    // v10: bind a sensor resource to a device, scope readers, unbind - all by
    // council vote with the wrapped PolicyAdminCap.
    #[test]
    fun device_binding_via_council() {
        let (mut sc, clk) = setup();
        let res = b"/in-cse/Cesp32-dht-01";
        let pid = propose_as(&mut sc, N2, quorum::act_policy_set(), @0x0, res, 50, 0x1, 0, TTL, &clk);
        approve_as(&mut sc, N1, pid, &clk);
        exec_policy_as(&mut sc, N1, pid, &clk);

        let pid = propose_as(&mut sc, N2, quorum::act_policy_bind_device(), SENSOR, res, 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N3, pid, &clk);
        exec_policy_as(&mut sc, N3, pid, &clk);

        let pid = propose_as(&mut sc, N1, quorum::act_policy_add_reader(), N2, res, 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, pid, &clk);
        exec_policy_as(&mut sc, N1, pid, &clk);

        ts::next_tx(&mut sc, N1);
        {
            let preg = ts::take_shared<PolicyRegistry>(&sc);
            let r = string::utf8(res);
            assert!(policy::is_device_bound(&preg, &r), 0);
            assert!(policy::bound_device(&preg, &r) == SENSOR, 1);
            assert!(policy::readers_of(&preg, &r) == vector[N2], 2);
            ts::return_shared(preg);
        };

        let pid = propose_as(&mut sc, N1, quorum::act_policy_remove_reader(), N2, res, 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N3, pid, &clk);
        exec_policy_as(&mut sc, N1, pid, &clk);
        let pid = propose_as(&mut sc, N1, quorum::act_policy_unbind_device(), @0x0, res, 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N3, pid, &clk);
        exec_policy_as(&mut sc, N1, pid, &clk);
        ts::next_tx(&mut sc, N1);
        {
            let preg = ts::take_shared<PolicyRegistry>(&sc);
            let r = string::utf8(res);
            assert!(!policy::is_device_bound(&preg, &r) && policy::has_policy(&preg, &r), 3);
            ts::return_shared(preg);
        };
        finish(sc, clk);
    }

    // One member alone cannot bind (or re-bind) a resource to a device.
    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::quorum)]
    fun device_binding_needs_quorum() {
        let (mut sc, clk) = setup();
        let pid = propose_as(&mut sc, N2, quorum::act_policy_bind_device(), SENSOR, b"/in-cse/Cesp32-dht-01", 0, 0, 0, TTL, &clk);
        exec_policy_as(&mut sc, N2, pid, &clk);
        finish(sc, clk);
    }

    #[test]
    fun token_mint_via_council() {
        let (mut sc, clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_token_mint(), N3, b"sui-protected-ae", T0 + 86_400_000, 100, 0x1, TTL, &clk);
        approve_as(&mut sc, N2, pid, &clk);
        ts::next_tx(&mut sc, N2);
        {
            let mut council = ts::take_shared<Council>(&sc);
            let treg = ts::take_shared<TrustRegistry>(&sc);
            quorum::execute_mint(&mut council, pid, &treg, &clk, ts::ctx(&mut sc));
            ts::return_shared(treg);
            ts::return_shared(council);
        };
        ts::next_tx(&mut sc, N3);
        let tok = ts::take_from_sender<CapToken>(&sc);
        assert!(cap_token::owner(&tok) == N3, 0);
        assert!(cap_token::allowed_ops(&tok) == 0x1, 1);
        assert!(cap_token::max_uses(&tok) == 100, 2);
        ts::return_to_sender(&sc, tok);
        finish(sc, clk);
    }

    #[test]
    fun cluster_gate_via_council() {
        let (mut sc, clk) = setup();
        ts::next_tx(&mut sc, ADMIN);
        let caddr = {
            let cl = ts::take_shared<Cluster>(&sc);
            let a = object::id_address(&cl);
            ts::return_shared(cl);
            a
        };
        let pid = propose_as(&mut sc, N3, quorum::act_cluster_set_gate(), caddr, b"", 65, 0, 0, TTL, &clk);
        approve_as(&mut sc, N1, pid, &clk);
        ts::next_tx(&mut sc, N1);
        {
            let mut council = ts::take_shared<Council>(&sc);
            let mut cl = ts::take_shared<Cluster>(&sc);
            let treg = ts::take_shared<TrustRegistry>(&sc);
            quorum::execute_cluster(&mut council, pid, &mut cl, &treg, &clk, ts::ctx(&mut sc));
            assert!(failover::trust_gate(&cl) == 65, 0);
            ts::return_shared(treg);
            ts::return_shared(cl);
            ts::return_shared(council);
        };
        finish(sc, clk);
    }

    #[test]
    fun grow_to_four_members_after_raising_threshold() {
        // k=2 of n=4 is not a strict majority, so the council must first
        // raise k to 3, then add the fourth member.
        let (mut sc, clk) = setup();
        let p1 = propose_as(&mut sc, N1, quorum::act_set_threshold(), @0x0, b"", 3, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, p1, &clk);
        exec_membership_as(&mut sc, N1, p1, &clk);
        let p2 = propose_as(&mut sc, N1, quorum::act_add_member(), N4, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, p2, &clk);
        approve_as(&mut sc, N3, p2, &clk);
        exec_membership_as(&mut sc, N3, p2, &clk);
        ts::next_tx(&mut sc, ADMIN);
        let council = ts::take_shared<Council>(&sc);
        assert!(quorum::is_member(&council, N4), 0);
        assert!(quorum::member_count(&council) == 4, 1);
        assert!(quorum::threshold(&council) == 3, 2);
        ts::return_shared(council);
        finish(sc, clk);
    }

    #[test]
    fun score_writes_stay_per_node_when_governed() {
        // Governance must not touch the hot path: a member still scores a
        // peer alone (bounded by A12), exactly as in v8.
        let (mut sc, mut clk) = setup();
        ts::next_tx(&mut sc, ADMIN);
        let pid = propose_as(&mut sc, N1, quorum::act_trust_add_node(), N2, b"", 50, 0, 0, TTL, &clk);
        approve_as(&mut sc, N3, pid, &clk);
        exec_trust_as(&mut sc, N1, pid, &clk);
        clock::increment_for_testing(&mut clk, 60_000);
        ts::next_tx(&mut sc, N1);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut treg = ts::take_shared<TrustRegistry>(&sc);
            trust::increase_guarded(&cap, &mut treg, N2, 5, &clk, ts::ctx(&mut sc));
            assert!(trust::score_of(&treg, N2, &clk) == 55, 0);
            ts::return_shared(treg);
            ts::return_to_sender(&sc, cap);
        };
        finish(sc, clk);
    }

    #[test]
    fun expired_proposal_can_be_discarded() {
        let (mut sc, mut clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_trust_grant_admin(), NEWNODE, b"", 0, 0, 0, TTL, &clk);
        clock::increment_for_testing(&mut clk, TTL);
        ts::next_tx(&mut sc, OUTSIDER);
        let mut council = ts::take_shared<Council>(&sc);
        quorum::discard_expired(&mut council, pid, &clk);
        assert!(!quorum::has_proposal(&council, pid), 0);
        ts::return_shared(council);
        finish(sc, clk);
    }

    // ==================================================================
    //  Attacks: single-holder paths are closed (limitation 2)
    // ==================================================================

    #[test]
    #[expected_failure(abort_code = 8, location = om2m_access::trust)]
    fun single_cap_revoke_admin_rejected() {
        // The pre-v9 attack: one compromised node revokes an honest node's cap.
        let (mut sc, clk) = setup();
        let vid = cap_id_of(&mut sc, N2);
        ts::next_tx(&mut sc, N1);
        let cap = ts::take_from_sender<AdminCap>(&sc);
        let mut treg = ts::take_shared<TrustRegistry>(&sc);
        trust::revoke_admin(&cap, &mut treg, vid, ts::ctx(&mut sc));
        ts::return_shared(treg);
        ts::return_to_sender(&sc, cap);
        finish(sc, clk);
    }

    #[test]
    fun self_revoke_stays_unilateral_when_governed() {
        // A node that suspects its key leaked can still kill its own cap alone.
        let (mut sc, clk) = setup();
        let own = cap_id_of(&mut sc, N2);
        ts::next_tx(&mut sc, N2);
        let cap = ts::take_from_sender<AdminCap>(&sc);
        let mut treg = ts::take_shared<TrustRegistry>(&sc);
        trust::revoke_admin(&cap, &mut treg, own, ts::ctx(&mut sc));
        assert!(!trust::is_cap_valid(&treg, own), 0);
        ts::return_shared(treg);
        ts::return_to_sender(&sc, cap);
        finish(sc, clk);
    }

    #[test]
    fun legacy_v8_check_passes_before_governance() {
        // Control for the next test: before the council exists, v8's check
        // accepts a valid cap.
        let (mut sc, clk) = base();
        ts::next_tx(&mut sc, N1);
        let cap = ts::take_from_sender<AdminCap>(&sc);
        let treg = ts::take_shared<TrustRegistry>(&sc);
        trust::legacy_v8_cap_check_for_testing(&cap, &treg);
        ts::return_shared(treg);
        ts::return_to_sender(&sc, cap);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 5, location = om2m_access::trust)]
    fun legacy_v8_paths_fail_closed_after_governance() {
        // Sui keeps v8 callable at its own package id, and v8's revoke_admin /
        // grant_admin / bootstrap_valid_caps / add_node have no governed
        // guard. All of them start with v8's assert_cap_valid; once the set
        // has moved to the v9 key, that check rejects every cap, even one
        // that is still valid under v9.
        let (mut sc, clk) = setup();
        ts::next_tx(&mut sc, N1);
        let cap = ts::take_from_sender<AdminCap>(&sc);
        let treg = ts::take_shared<TrustRegistry>(&sc);
        assert!(trust::is_cap_valid(&treg, object::id(&cap)), 0);
        trust::legacy_v8_cap_check_for_testing(&cap, &treg);
        ts::return_shared(treg);
        ts::return_to_sender(&sc, cap);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = om2m_access::trust)]
    fun single_cap_grant_admin_rejected() {
        let (mut sc, clk) = setup();
        ts::next_tx(&mut sc, N1);
        let cap = ts::take_from_sender<AdminCap>(&sc);
        let mut treg = ts::take_shared<TrustRegistry>(&sc);
        trust::grant_admin(&cap, &mut treg, OUTSIDER, ts::ctx(&mut sc));
        ts::return_shared(treg);
        ts::return_to_sender(&sc, cap);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = om2m_access::trust)]
    fun single_cap_grant_admin_registered_rejected() {
        // Even the publisher's genesis cap has lost unilateral delegation.
        let (mut sc, clk) = setup();
        ts::next_tx(&mut sc, ADMIN);
        let cap = ts::take_from_sender<AdminCap>(&sc);
        let mut treg = ts::take_shared<TrustRegistry>(&sc);
        trust::grant_admin_registered(&cap, &mut treg, OUTSIDER, ts::ctx(&mut sc));
        ts::return_shared(treg);
        ts::return_to_sender(&sc, cap);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = om2m_access::trust)]
    fun single_cap_unrevoke_via_bootstrap_rejected() {
        // After the council revokes N3, N1 tries to put N3's id back.
        let (mut sc, clk) = setup();
        let vid = cap_id_of(&mut sc, N3);
        council_revokes(&mut sc, N3, &clk);
        ts::next_tx(&mut sc, N1);
        let cap = ts::take_from_sender<AdminCap>(&sc);
        let mut treg = ts::take_shared<TrustRegistry>(&sc);
        trust::bootstrap_valid_caps(&cap, &mut treg, vector[vid], ts::ctx(&mut sc));
        ts::return_shared(treg);
        ts::return_to_sender(&sc, cap);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = om2m_access::trust)]
    fun single_cap_add_node_rejected() {
        let (mut sc, clk) = setup();
        ts::next_tx(&mut sc, N1);
        let cap = ts::take_from_sender<AdminCap>(&sc);
        let mut treg = ts::take_shared<TrustRegistry>(&sc);
        trust::add_node(&cap, &mut treg, OUTSIDER, 100, &clk);
        ts::return_shared(treg);
        ts::return_to_sender(&sc, cap);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = om2m_access::trust)]
    fun second_council_cannot_take_over() {
        // Arming is one-way. Even with another identity cap (impossible on
        // chain, where identity::init runs once), a second council can't
        // re-point the trust registry.
        let (mut sc, clk) = setup();
        ts::next_tx(&mut sc, ADMIN);
        let reg_id = {
            let ireg = ts::take_shared<IdentityRegistry>(&sc);
            let id = object::id(&ireg);
            ts::return_shared(ireg);
            id
        };
        identity::init_for_testing(ts::ctx(&mut sc));
        ts::next_tx(&mut sc, ADMIN);
        let icap = ts::take_from_sender<IdentityAdminCap>(&sc);
        let tcap = ts::take_from_sender<AdminCap>(&sc);
        let ireg = ts::take_shared_by_id<IdentityRegistry>(&sc, reg_id);
        let mut treg = ts::take_shared<TrustRegistry>(&sc);
        quorum::create_council(icap, &ireg, &tcap, &mut treg, vector[N1, N2, N3], 2, ts::ctx(&mut sc));
        ts::return_shared(ireg);
        ts::return_shared(treg);
        ts::return_to_sender(&sc, tcap);
        finish(sc, clk);
    }

    // ==================================================================
    //  Attacks on the proposal flow
    // ==================================================================

    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::quorum)]
    fun one_approval_is_not_quorum() {
        let (mut sc, clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_trust_grant_admin(), OUTSIDER, b"", 0, 0, 0, TTL, &clk);
        exec_trust_as(&mut sc, N1, pid, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = om2m_access::quorum)]
    fun double_approval_rejected() {
        let (mut sc, clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_trust_grant_admin(), OUTSIDER, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N1, pid, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 5, location = om2m_access::quorum)]
    fun replay_of_executed_proposal_rejected() {
        let (mut sc, clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_trust_grant_admin(), NEWNODE, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, pid, &clk);
        exec_trust_as(&mut sc, N1, pid, &clk);
        exec_trust_as(&mut sc, N1, pid, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::quorum)]
    fun approve_after_expiry_rejected() {
        let (mut sc, mut clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_trust_grant_admin(), NEWNODE, b"", 0, 0, 0, TTL, &clk);
        clock::increment_for_testing(&mut clk, TTL);
        approve_as(&mut sc, N2, pid, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::quorum)]
    fun execute_after_expiry_rejected() {
        let (mut sc, mut clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_trust_grant_admin(), NEWNODE, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, pid, &clk);
        clock::increment_for_testing(&mut clk, TTL);
        exec_trust_as(&mut sc, N1, pid, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = om2m_access::quorum)]
    fun non_member_cannot_propose() {
        // N4 is a registered MN-CSE with a valid trust cap, but not a member.
        let (mut sc, clk) = setup();
        propose_as(&mut sc, N4, quorum::act_trust_grant_admin(), N4, b"", 0, 0, 0, TTL, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = om2m_access::quorum)]
    fun non_member_cannot_execute() {
        let (mut sc, clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_trust_grant_admin(), NEWNODE, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, pid, &clk);
        exec_trust_as(&mut sc, OUTSIDER, pid, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 9, location = om2m_access::quorum)]
    fun member_with_revoked_cap_cannot_approve() {
        let (mut sc, clk) = setup();
        council_revokes(&mut sc, N3, &clk);
        let pid = propose_as(&mut sc, N1, quorum::act_trust_grant_admin(), NEWNODE, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N3, pid, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::quorum)]
    fun approval_from_since_revoked_cap_stops_counting() {
        // N3 proposes (approval recorded), then the council revokes N3's cap.
        // N1's approval alone is not enough: N3's earlier vote is void.
        let (mut sc, clk) = setup();
        let p0 = propose_as(&mut sc, N3, quorum::act_trust_grant_admin(), OUTSIDER, b"", 0, 0, 0, TTL, &clk);
        council_revokes(&mut sc, N3, &clk);
        approve_as(&mut sc, N1, p0, &clk);
        exec_trust_as(&mut sc, N1, p0, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::quorum)]
    fun approval_from_removed_member_stops_counting() {
        let (mut sc, clk) = setup();
        let p0 = propose_as(&mut sc, N3, quorum::act_trust_grant_admin(), OUTSIDER, b"", 0, 0, 0, TTL, &clk);
        let p1 = propose_as(&mut sc, N1, quorum::act_remove_member(), N3, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, p1, &clk);
        exec_membership_as(&mut sc, N1, p1, &clk);
        approve_as(&mut sc, N1, p0, &clk);
        exec_trust_as(&mut sc, N1, p0, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = om2m_access::quorum)]
    fun proposal_cannot_run_through_wrong_executor() {
        // A membership proposal must not be executable as a trust action.
        let (mut sc, clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_add_member(), N4, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, pid, &clk);
        exec_trust_as(&mut sc, N1, pid, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = om2m_access::quorum)]
    fun unknown_action_rejected() {
        let (mut sc, clk) = setup();
        propose_as(&mut sc, N1, 77, N4, b"", 0, 0, 0, TTL, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 10, location = om2m_access::quorum)]
    fun ttl_above_max_rejected() {
        let (mut sc, clk) = setup();
        propose_as(&mut sc, N1, quorum::act_trust_grant_admin(), NEWNODE, b"", 0, 0, 0, 604_800_001, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 11, location = om2m_access::quorum)]
    fun cannot_deregister_a_sitting_member() {
        let (mut sc, clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_id_deregister(), N3, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, pid, &clk);
        exec_identity_as(&mut sc, N1, pid, &clk);
        finish(sc, clk);
    }

    // ==================================================================
    //  Threshold and membership invariants
    // ==================================================================

    #[test]
    #[expected_failure(abort_code = 7, location = om2m_access::quorum)]
    fun threshold_of_one_rejected() {
        let (mut sc, clk) = base();
        create_council_with(&mut sc, vector[N1, N2, N3], 1);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = om2m_access::quorum)]
    fun non_majority_threshold_rejected() {
        let (mut sc, clk) = base();
        create_council_with(&mut sc, vector[N1, N2, N3, N4], 2);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = om2m_access::quorum)]
    fun ae_cannot_be_member() {
        let (mut sc, clk) = base();
        create_council_with(&mut sc, vector[N1, N2, SENSOR], 2);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = om2m_access::quorum)]
    fun unregistered_address_cannot_be_member() {
        let (mut sc, clk) = base();
        create_council_with(&mut sc, vector[N1, N2, OUTSIDER], 2);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 16, location = om2m_access::quorum)]
    fun duplicate_member_rejected() {
        // [N1, N1, N2] must not count N1 twice toward n.
        let (mut sc, clk) = base();
        create_council_with(&mut sc, vector[N1, N1, N2], 2);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = om2m_access::quorum)]
    fun adding_member_that_breaks_majority_rejected() {
        let (mut sc, clk) = setup();
        let pid = propose_as(&mut sc, N1, quorum::act_add_member(), N4, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, pid, &clk);
        exec_membership_as(&mut sc, N1, pid, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = om2m_access::quorum)]
    fun removing_below_threshold_rejected() {
        let (mut sc, clk) = setup();
        let p1 = propose_as(&mut sc, N1, quorum::act_remove_member(), N3, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, p1, &clk);
        exec_membership_as(&mut sc, N1, p1, &clk);
        let p2 = propose_as(&mut sc, N1, quorum::act_remove_member(), N2, b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, p2, &clk);
        exec_membership_as(&mut sc, N1, p2, &clk);
        finish(sc, clk);
    }

    // ==================================================================
    //  5-node council (3-of-5)
    // ==================================================================

    #[test]
    fun five_member_council_is_three_of_five() {
        let (mut sc, clk) = setup5();
        ts::next_tx(&mut sc, ADMIN);
        let council = ts::take_shared<Council>(&sc);
        assert!(quorum::member_count(&council) == 5, 0);
        assert!(quorum::threshold(&council) == 3, 1);
        ts::return_shared(council);
        finish(sc, clk);
    }

    #[test]
    fun revoke_admin_with_three_of_five() {
        let (mut sc, clk) = setup5();
        let vid = cap_id_of(&mut sc, N5);
        let pid = propose_as(&mut sc, N1, quorum::act_trust_revoke_admin(), object::id_to_address(&vid), b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, pid, &clk);
        approve_as(&mut sc, N4, pid, &clk);
        exec_trust_as(&mut sc, N3, pid, &clk);
        ts::next_tx(&mut sc, ADMIN);
        let treg = ts::take_shared<TrustRegistry>(&sc);
        assert!(!trust::is_cap_valid(&treg, vid), 0);
        ts::return_shared(treg);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::quorum)]
    fun two_of_five_is_not_quorum() {
        // Two colluding nodes of five must not be able to revoke a peer.
        let (mut sc, clk) = setup5();
        let vid = cap_id_of(&mut sc, N5);
        let pid = propose_as(&mut sc, N1, quorum::act_trust_revoke_admin(), object::id_to_address(&vid), b"", 0, 0, 0, TTL, &clk);
        approve_as(&mut sc, N2, pid, &clk);
        exec_trust_as(&mut sc, N1, pid, &clk);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = om2m_access::quorum)]
    fun five_member_council_with_threshold_two_rejected() {
        // k = 2 of n = 5 is not a strict majority.
        let (mut sc, clk) = base();
        create_council_with(&mut sc, vector[N1, N2, N3, N4, N5], 2);
        finish(sc, clk);
    }
}
