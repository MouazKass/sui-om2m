// trust_revocation_tests.move
//
// Offline unit proof of invariant TR7: a revoked AdminCap can no longer write
// trust scores. Mirrors the live demonstration on the v5 package (see
// TR7_EVIDENCE.md), where a throwaway cap was granted, used to score, revoked,
// and then re-scoring aborted in trust::assert_cap_valid with E_CAP_REVOKED.
//
// It also covers the v8 A12 fix: per-entry rate limiting on score writes.
//
//   trust error codes:  E_SELF_SCORING = 4,  E_CAP_REVOKED = 5,
//                       E_DELTA_TOO_LARGE = 6,  E_RATE_LIMITED = 7
//
// Design notes reflected here:
//   * v8 `trust::init` registers the genesis AdminCap in the validity set and
//     writes the BOOTSTRAPPED_KEY marker in the same transaction, so
//     assert_cap_valid is fail-CLOSED from genesis. The old fail-open window
//     is no longer observable on a v8 package. `bootstrap_with_original` is
//     kept because it still exercises the (now cap-gated, A2) bootstrap entry
//     point and proves it is idempotent.
//   * increase_guarded checks self-scoring (E_SELF_SCORING) BEFORE the cap
//     check, so the scored node_addr must differ from the tx sender.
//   * A12: increase/decrease now reject a delta > MAX_DELTA (15) and any
//     write less than MIN_INTERVAL_MS (60_000) after the entry's
//     last_update_ms. add_node sets last_update_ms = now, so a freshly
//     seeded node cannot be scored until the clock has advanced 60s. Every
//     positive scoring test below advances the test Clock accordingly — that
//     is the one behavioural change A12 forced on this file.
//   * Guard ordering inside increase_guarded/decrease_guarded is:
//     self-scoring -> cap validity -> entry exists -> delta bound -> rate
//     bound. Each negative test below satisfies all the earlier guards so the
//     intended one is the one that fires.
//
// Run with:  sui move test

#[test_only]
module om2m_access::trust_revocation_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};
    use sui::object;

    use om2m_access::trust::{Self, TrustRegistry, AdminCap};

    const ADMIN: address = @0xA11CE;   // original publisher / cap holder
    const NEWCAP_HOLDER: address = @0xCA9; // receives the granted cap
    const NODE: address = @0xB0B;      // node being scored (!= sender)

    fun setup(): Scenario {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut sc);
            trust::init_for_testing(ctx);
        };
        sc
    }

    fun mk_clock(sc: &mut Scenario): Clock {
        clock::create_for_testing(ts::ctx(sc))
    }

    // Seed NODE with a starting score so increase has an entry to mutate.
    fun seed_node(sc: &mut Scenario, clk: &Clock) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let mut reg = ts::take_shared<TrustRegistry>(sc);
        trust::add_node(&cap, &mut reg, NODE, 50, clk);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    // Bootstrap the validity set with the ORIGINAL admin cap's id (arms
    // fail-closed enforcement), and return nothing.
    fun bootstrap_with_original(sc: &mut Scenario) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let mut reg = ts::take_shared<TrustRegistry>(sc);
        let ids = vector[ object::id(&cap) ];
        trust::bootstrap_valid_caps(&cap, &mut reg, ids, ts::ctx(sc));
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    // ---- TR7: revoked cap cannot score --------------------------------

    // Bootstrap -> grant a registered cap to NEWCAP_HOLDER -> revoke it ->
    // NEWCAP_HOLDER tries to score NODE with the revoked cap -> E_CAP_REVOKED(5).
    #[test]
    #[expected_failure(abort_code = 5, location = om2m_access::trust)]
    fun tr7_revoked_cap_cannot_score() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        seed_node(&mut sc, &clk);
        bootstrap_with_original(&mut sc);
        // Advance past MIN_INTERVAL_MS so an A12 rate-limit abort (code 7)
        // cannot be mistaken for the cap-revocation abort (code 5) we assert.
        clock::set_for_testing(&mut clk, 60_000);

        // ADMIN grants a registered cap to NEWCAP_HOLDER.
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::grant_admin_registered(&cap, &mut reg, NEWCAP_HOLDER, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        // ADMIN revokes the new cap by its id.
        ts::next_tx(&mut sc, NEWCAP_HOLDER); // settle the transfer to holder
        let new_cap = ts::take_from_sender<AdminCap>(&mut sc);
        let new_cap_id = object::id(&new_cap);
        ts::return_to_sender(&mut sc, new_cap);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::revoke_admin(&cap, &mut reg, new_cap_id, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        // NEWCAP_HOLDER attempts to score NODE with the REVOKED cap -> abort 5.
        ts::next_tx(&mut sc, NEWCAP_HOLDER);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::increase_guarded(&cap, &mut reg, NODE, 5, &clk, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Positive control: a bootstrapped, NON-revoked cap scores fine.
    #[test]
    fun tr7_valid_cap_can_score() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        seed_node(&mut sc, &clk);
        bootstrap_with_original(&mut sc);

        // grant a registered cap to NEWCAP_HOLDER (NOT revoked)
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::grant_admin_registered(&cap, &mut reg, NEWCAP_HOLDER, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        // A12: NODE's entry was created at t=0, so the first write to it is
        // only legal once MIN_INTERVAL_MS (60_000) has elapsed.
        clock::set_for_testing(&mut clk, 60_000);

        // NEWCAP_HOLDER scores NODE successfully with the valid cap.
        ts::next_tx(&mut sc, NEWCAP_HOLDER);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::increase_guarded(&cap, &mut reg, NODE, 5, &clk, ts::ctx(&mut sc));
            // NODE was 50, +5 -> 55
            assert!(trust::score_of(&reg, NODE, &clk) == 55, 0);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // TR7 burn: a held cap is destroyed by burn_admin. Before burn it is in
    // the validity set (is_cap_valid -> true); after burn it is gone from the
    // set (is_cap_valid -> false) and the object no longer exists. Mirrors the
    // full cap lifecycle: mint -> grant -> revoke -> burn.
    #[test]
    fun tr7_burn_removes_cap() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        seed_node(&mut sc, &clk);
        bootstrap_with_original(&mut sc);

        // grant a registered cap to NEWCAP_HOLDER
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::grant_admin_registered(&cap, &mut reg, NEWCAP_HOLDER, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        // capture the new cap id; confirm it is valid before burning
        ts::next_tx(&mut sc, NEWCAP_HOLDER);
        let cap0 = ts::take_from_sender<AdminCap>(&mut sc);
        let cap_id = object::id(&cap0);
        ts::return_to_sender(&mut sc, cap0);
        ts::next_tx(&mut sc, NEWCAP_HOLDER);
        {
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            assert!(trust::is_cap_valid(&reg, cap_id), 0); // valid before burn
            ts::return_shared(reg);
        };

        // NEWCAP_HOLDER self-burns its cap
        ts::next_tx(&mut sc, NEWCAP_HOLDER);
        {
            let to_burn = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::burn_admin(&mut reg, to_burn, ts::ctx(&mut sc));
            assert!(!trust::is_cap_valid(&reg, cap_id), 1); // gone from set after burn
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ---- A12: per-entry rate limiting on score writes -------------------
    //
    // MAX_DELTA = 15 points per write, MIN_INTERVAL_MS = 60_000 between
    // writes on the same entry, both enforced against the entry's existing
    // last_update_ms. Together they bound the damage a compromised-but-not-
    // yet-revoked AdminCap can do to a score.

    // Negative 1: a single oversized write is rejected -> E_DELTA_TOO_LARGE(6).
    // The clock is advanced past MIN_INTERVAL_MS first so the DELTA bound is
    // unambiguously the guard that fires.
    #[test]
    #[expected_failure(abort_code = 6, location = om2m_access::trust)]
    fun a12_delta_above_max_is_rejected() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        seed_node(&mut sc, &clk);               // NODE = 50 at t=0
        clock::set_for_testing(&mut clk, 60_000); // rate window satisfied

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            // 16 > MAX_DELTA(15). Pre-A12 an admin could drive 100 -> 0 in a
            // single transaction.
            trust::decrease_guarded(&cap, &mut reg, NODE, 16, &clk, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Negative 2: a legal-sized write that arrives too soon after the
    // previous one is rejected -> E_RATE_LIMITED (7). Delta is 5 (well inside
    // MAX_DELTA) so the INTERVAL bound is the guard that fires.
    #[test]
    #[expected_failure(abort_code = 7, location = om2m_access::trust)]
    fun a12_write_too_soon_is_rejected() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        seed_node(&mut sc, &clk);                 // last_update_ms = 0
        clock::set_for_testing(&mut clk, 59_999); // one ms short of the window

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::decrease_guarded(&cap, &mut reg, NODE, 5, &clk, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Negative 3: the burst case the interval bound exists to stop — a second
    // write in the same instant as a successful first one -> E_RATE_LIMITED(7).
    #[test]
    #[expected_failure(abort_code = 7, location = om2m_access::trust)]
    fun a12_second_write_in_same_instant_is_rejected() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        seed_node(&mut sc, &clk);
        clock::set_for_testing(&mut clk, 60_000);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::decrease_guarded(&cap, &mut reg, NODE, 15, &clk, ts::ctx(&mut sc)); // ok
            // Same clock value, so last_update_ms == now -> rate limited.
            trust::decrease_guarded(&cap, &mut reg, NODE, 15, &clk, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Positive control: writes at exactly the limits are accepted, and the
    // score moves by exactly the requested delta each time.
    #[test]
    fun a12_writes_within_limits_are_accepted() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        seed_node(&mut sc, &clk); // NODE = 50 at t=0

        // delta == MAX_DELTA exactly, now == last_update + MIN_INTERVAL exactly
        clock::set_for_testing(&mut clk, 60_000);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::increase_guarded(&cap, &mut reg, NODE, 15, &clk, ts::ctx(&mut sc));
            assert!(trust::score_of(&reg, NODE, &clk) == 65, 0);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        // a second window later, another legal write
        clock::set_for_testing(&mut clk, 120_000);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::decrease_guarded(&cap, &mut reg, NODE, 15, &clk, ts::ctx(&mut sc));
            assert!(trust::score_of(&reg, NODE, &clk) == 50, 1);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ---- Assume-breach guard: nodes never self-attest -------------------

    // Negative: the signer cannot score itself -> E_SELF_SCORING (4).
    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::trust)]
    fun self_scoring_is_rejected() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        seed_node(&mut sc, &clk);
        clock::set_for_testing(&mut clk, 60_000);

        // ADMIN holds a valid cap AND is the subject of the write.
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::add_node(&cap, &mut reg, ADMIN, 50, &clk);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        clock::set_for_testing(&mut clk, 120_000);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::increase_guarded(&cap, &mut reg, ADMIN, 5, &clk, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }
}
