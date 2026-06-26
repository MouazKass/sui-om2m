// trust_revocation_tests.move
//
// Offline unit proof of invariant TR7: a revoked AdminCap can no longer write
// trust scores. Mirrors the live demonstration on the v5 package (see
// TR7_EVIDENCE.md), where a throwaway cap was granted, used to score, revoked,
// and then re-scoring aborted in trust::assert_cap_valid with E_CAP_REVOKED.
//
//   trust error codes:  E_SELF_SCORING = 4,  E_CAP_REVOKED = 5
//
// Design notes reflected here:
//   * assert_cap_valid is FAIL-OPEN until bootstrap_valid_caps is called, then
//     FAIL-CLOSED. So the revocation test must bootstrap first.
//   * increase_guarded checks self-scoring (E_SELF_SCORING) BEFORE the cap
//     check, so the scored node_addr must differ from the tx sender.
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
        let clk = mk_clock(&mut sc);
        seed_node(&mut sc, &clk);
        bootstrap_with_original(&mut sc);

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
        let clk = mk_clock(&mut sc);
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

}
