// deny_batch_tests.move
//
// v9 (F3): batched, on-chain anchoring of each node's local DENY log
// (evaluator::log_deny_batch -> audit::log_deny_batch).
//
// Since the plugin's free pre-check, a DENY is never submitted as a
// transaction, so no gas can be drained by repeating a forbidden request.
// These tests prove that the replacement on-chain record cannot be abused
// either: only a registered IN/MN-CSE holding a valid trust AdminCap can
// write it, at most once per 5 minutes per node, with non-overlapping
// windows and a well-formed digest.
//
//   audit error codes:     E_BAD_DIGEST 2, E_EMPTY_BATCH 3, E_BAD_WINDOW 4,
//                          E_BATCH_TOO_SOON 5, E_WINDOW_OVERLAP 6
//   evaluator error codes: E_NOT_MIDDLEWARE 100, E_NODE_CAP_INVALID 101
//   identity error codes:  E_NOT_REGISTERED 1
//
// Run with:  sui move test

#[test_only]
module om2m_access::deny_batch_tests {
    use std::string;
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};
    use sui::object;

    use om2m_access::identity::{Self, Registry as IdentityRegistry, AdminCap as IdentityAdminCap};
    use om2m_access::trust::{Self, TrustRegistry, AdminCap};
    use om2m_access::audit::{Self, AuditTrail};
    use om2m_access::evaluator;
    use om2m_access::quorum;

    const ADMIN: address = @0xA11CE;
    const N1: address = @0x1;
    const N2: address = @0x2;
    const N3: address = @0x3;
    const SENSOR: address = @0xAE;      // registered, but an AE
    const OUTSIDER: address = @0xBAD;   // holds a trust cap, not registered

    const T0: u64 = 200_000_000;
    const MIN: u64 = 300_000;           // audit::DENY_BATCH_MIN_INTERVAL_MS

    fun d32(): vector<u8> {
        let mut v = vector[];
        let mut i = 0;
        while (i < 32) { vector::push_back(&mut v, (i as u8)); i = i + 1; };
        v
    }

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

    fun setup(): (Scenario, Clock) {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut sc);
            identity::init_for_testing(ctx);
            trust::init_for_testing(ctx);
            audit::init_for_testing(ctx);
        };
        let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, T0);
        register(&mut sc, N1, identity::role_mn_cse());
        register(&mut sc, N2, identity::role_in_cse());
        register(&mut sc, N3, identity::role_mn_cse());
        register(&mut sc, SENSOR, identity::role_ae());
        grant_trust_cap(&mut sc, N1);
        grant_trust_cap(&mut sc, N2);
        grant_trust_cap(&mut sc, N3);
        grant_trust_cap(&mut sc, SENSOR);
        grant_trust_cap(&mut sc, OUTSIDER);
        (sc, clk)
    }

    fun finish(sc: Scenario, clk: Clock) {
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    /// The exact PTB the plugin builds: identity::verify -> evaluator::log_deny_batch.
    fun log_as(sc: &mut Scenario, clk: &Clock, who: address,
               start: u64, end: u64, count: u64, distinct: u64, digest: vector<u8>) {
        ts::next_tx(sc, who);
        let ireg = ts::take_shared<IdentityRegistry>(sc);
        let treg = ts::take_shared<TrustRegistry>(sc);
        let mut trail = ts::take_shared<AuditTrail>(sc);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let receipt = identity::verify(&ireg, ts::ctx(sc));
        evaluator::log_deny_batch(receipt, &ireg, &cap, &treg, &mut trail,
                                  start, end, count, distinct, digest, clk);
        ts::return_to_sender(sc, cap);
        ts::return_shared(trail);
        ts::return_shared(treg);
        ts::return_shared(ireg);
    }

    fun batches(sc: &mut Scenario): u64 {
        ts::next_tx(sc, ADMIN);
        let trail = ts::take_shared<AuditTrail>(sc);
        let n = audit::deny_batch_count(&trail);
        ts::return_shared(trail);
        n
    }

    // ------------------------------------------------------------------
    //  Positive controls
    // ------------------------------------------------------------------

    #[test]
    fun node_anchors_a_batch() {
        let (mut sc, clk) = setup();
        assert!(batches(&mut sc) == 0, 0);
        log_as(&mut sc, &clk, N1, T0 - 600_000, T0, 42, 3, d32());
        ts::next_tx(&mut sc, ADMIN);
        let trail = ts::take_shared<AuditTrail>(&sc);
        assert!(audit::deny_batch_count(&trail) == 1, 1);
        let (node, s, e, c, d, dig, at) = audit::latest_deny_batch(&trail);
        assert!(node == N1, 2);
        assert!(s == T0 - 600_000 && e == T0, 3);
        assert!(c == 42 && d == 3, 4);
        assert!(dig == d32(), 5);
        assert!(at == T0, 6);
        // Batching never touches the per-decision ring.
        assert!(audit::count(&trail) == 0, 7);
        ts::return_shared(trail);
        finish(sc, clk);
    }

    #[test]
    fun next_batch_after_the_interval_is_accepted() {
        let (mut sc, mut clk) = setup();
        log_as(&mut sc, &clk, N1, T0 - 600_000, T0, 5, 1, d32());
        clock::set_for_testing(&mut clk, T0 + MIN);
        log_as(&mut sc, &clk, N1, T0, T0 + MIN, 7, 2, d32());
        assert!(batches(&mut sc) == 2, 0);
        finish(sc, clk);
    }

    #[test]
    fun nodes_are_rate_limited_independently() {
        let (mut sc, clk) = setup();
        log_as(&mut sc, &clk, N1, T0 - 1000, T0, 1, 1, d32());
        log_as(&mut sc, &clk, N2, T0 - 1000, T0, 1, 1, d32());   // IN-CSE is eligible too
        log_as(&mut sc, &clk, N3, T0 - 1000, T0, 1, 1, d32());
        assert!(batches(&mut sc) == 3, 0);
        finish(sc, clk);
    }

    #[test]
    fun small_clock_lead_is_tolerated() {
        // A node clock up to 60 s ahead of the chain clock is not an error.
        let (mut sc, clk) = setup();
        log_as(&mut sc, &clk, N1, T0 - 1000, T0 + 60_000, 1, 1, d32());
        assert!(batches(&mut sc) == 1, 0);
        finish(sc, clk);
    }

    #[test]
    fun ring_keeps_the_latest_after_wrapping() {
        let (mut sc, mut clk) = setup();
        let mut i = 0;
        let mut now = T0;
        while (i < 257) {
            log_as(&mut sc, &clk, N1, now - 1000, now, i + 1, 1, d32());
            now = now + MIN;
            clock::set_for_testing(&mut clk, now);
            i = i + 1;
        };
        ts::next_tx(&mut sc, ADMIN);
        let trail = ts::take_shared<AuditTrail>(&sc);
        assert!(audit::deny_batch_count(&trail) == 257, 0);
        let (_, _, _, c, _, _, _) = audit::latest_deny_batch(&trail);
        assert!(c == 257, 1);
        ts::return_shared(trail);
        finish(sc, clk);
    }

    #[test]
    fun still_works_once_the_registry_is_governed() {
        // trust::is_cap_valid follows the v9 cap set after council creation.
        let (mut sc, clk) = setup();
        ts::next_tx(&mut sc, ADMIN);
        {
            let icap = ts::take_from_sender<IdentityAdminCap>(&sc);
            let tcap = ts::take_from_sender<AdminCap>(&sc);
            let ireg = ts::take_shared<IdentityRegistry>(&sc);
            let mut treg = ts::take_shared<TrustRegistry>(&sc);
            quorum::create_council(icap, &ireg, &tcap, &mut treg, vector[N1, N2, N3], 2, ts::ctx(&mut sc));
            assert!(trust::is_governed(&treg), 0);
            ts::return_shared(ireg);
            ts::return_shared(treg);
            ts::return_to_sender(&sc, tcap);
        };
        log_as(&mut sc, &clk, N1, T0 - 1000, T0, 3, 2, d32());
        assert!(batches(&mut sc) == 1, 1);
        finish(sc, clk);
    }

    // ------------------------------------------------------------------
    //  Who may write
    // ------------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = 100, location = om2m_access::evaluator)]
    fun an_ae_cannot_anchor_batches() {
        let (mut sc, clk) = setup();
        log_as(&mut sc, &clk, SENSOR, T0 - 1000, T0, 1, 1, d32());
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = om2m_access::identity)]
    fun an_unregistered_cap_holder_cannot_anchor_batches() {
        let (mut sc, clk) = setup();
        log_as(&mut sc, &clk, OUTSIDER, T0 - 1000, T0, 1, 1, d32());
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 101, location = om2m_access::evaluator)]
    fun a_revoked_cap_cannot_anchor_batches() {
        let (mut sc, clk) = setup();
        ts::next_tx(&mut sc, N1);
        {
            let cap = ts::take_from_sender<AdminCap>(&sc);
            let mut treg = ts::take_shared<TrustRegistry>(&sc);
            trust::revoke_admin(&cap, &mut treg, object::id(&cap), ts::ctx(&mut sc));
            ts::return_shared(treg);
            ts::return_to_sender(&sc, cap);
        };
        log_as(&mut sc, &clk, N1, T0 - 1000, T0, 1, 1, d32());
        finish(sc, clk);
    }

    // ------------------------------------------------------------------
    //  Rate limit and replay
    // ------------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = 5, location = om2m_access::audit)]
    fun a_second_batch_inside_the_interval_is_rejected() {
        let (mut sc, mut clk) = setup();
        log_as(&mut sc, &clk, N1, T0 - 1000, T0, 1, 1, d32());
        clock::set_for_testing(&mut clk, T0 + MIN - 1);
        log_as(&mut sc, &clk, N1, T0, T0 + MIN - 1, 1, 1, d32());
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = om2m_access::audit)]
    fun an_overlapping_window_is_rejected() {
        let (mut sc, mut clk) = setup();
        log_as(&mut sc, &clk, N1, T0 - 1000, T0, 1, 1, d32());
        clock::set_for_testing(&mut clk, T0 + MIN);
        log_as(&mut sc, &clk, N1, T0 - 1, T0 + MIN, 1, 1, d32());
        finish(sc, clk);
    }

    // ------------------------------------------------------------------
    //  Well-formedness
    // ------------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = 2, location = om2m_access::audit)]
    fun a_short_digest_is_rejected() {
        let (mut sc, clk) = setup();
        log_as(&mut sc, &clk, N1, T0 - 1000, T0, 1, 1, b"short");
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::audit)]
    fun an_empty_batch_is_rejected() {
        let (mut sc, clk) = setup();
        log_as(&mut sc, &clk, N1, T0 - 1000, T0, 0, 0, d32());
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::audit)]
    fun more_distinct_keys_than_denials_is_rejected() {
        let (mut sc, clk) = setup();
        log_as(&mut sc, &clk, N1, T0 - 1000, T0, 2, 3, d32());
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::audit)]
    fun an_inverted_window_is_rejected() {
        let (mut sc, clk) = setup();
        log_as(&mut sc, &clk, N1, T0, T0, 1, 1, d32());
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::audit)]
    fun a_window_longer_than_a_day_is_rejected() {
        let (mut sc, clk) = setup();
        log_as(&mut sc, &clk, N1, T0 - 86_400_001, T0, 1, 1, d32());
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::audit)]
    fun a_window_ending_in_the_future_is_rejected() {
        let (mut sc, clk) = setup();
        log_as(&mut sc, &clk, N1, T0 - 1000, T0 + 60_001, 1, 1, d32());
        finish(sc, clk);
    }
}
