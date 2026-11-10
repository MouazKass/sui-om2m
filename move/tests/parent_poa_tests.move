// parent_poa_tests.move
//
// v9 (finding F2): the parent PoA stored on a Cluster must follow the parent.
// Live on v8, after rpi3 took over, followers kept reading rpi1's old PoA,
// because claim_parent never touched the field and nothing recorded who set it.
//
//   failover error codes: E_NOT_PARENT = 6 (set_parent_poa by a non-parent)
//
// Run with:  sui move test

#[test_only]
module om2m_access::parent_poa_tests {
    use std::string;
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};

    use om2m_access::identity::{Self, Registry as IdRegistry, AdminCap as IdAdminCap};
    use om2m_access::trust::{Self, TrustRegistry, AdminCap as TrustAdminCap};
    use om2m_access::failover::{Self, Cluster};

    const ADMIN: address     = @0xA11CE;
    const PARENT: address    = @0xBEEF;
    const CANDIDATE: address = @0xC0FFEE;
    const ATTACKER: address  = @0xBAD;

    const OLD_POA: vector<u8> = b"https://10.25.96.200:8443";
    const NEW_POA: vector<u8> = b"https://10.25.96.203:8443";

    // Parent and candidate are eligible MN-CSEs with trust 80 > gate 60;
    // the cluster lease (60 s) has expired by the time the test runs.
    fun setup(): (Scenario, Clock) {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut sc);
            identity::init_for_testing(ctx);
            trust::init_for_testing(ctx);
        };
        let clk = clock::create_for_testing(ts::ctx(&mut sc));
        ts::next_tx(&mut sc, ADMIN);
        failover::create_cluster(b"EE_5", PARENT, 60, 60_000, &clk, ts::ctx(&mut sc));
        let mut v = vector[PARENT, CANDIDATE];
        while (!vector::is_empty(&v)) {
            let who = vector::pop_back(&mut v);
            ts::next_tx(&mut sc, ADMIN);
            let icap = ts::take_from_sender<IdAdminCap>(&sc);
            let mut ireg = ts::take_shared<IdRegistry>(&sc);
            identity::register(&icap, &mut ireg, who, string::utf8(b"mn"), identity::role_mn_cse(), 0);
            ts::return_shared(ireg);
            ts::return_to_sender(&sc, icap);
            let tcap = ts::take_from_sender<TrustAdminCap>(&sc);
            let mut treg = ts::take_shared<TrustRegistry>(&sc);
            trust::add_node(&tcap, &mut treg, who, 80, &clk);
            ts::return_shared(treg);
            ts::return_to_sender(&sc, tcap);
        };
        (sc, clk)
    }

    fun set_poa_as(sc: &mut Scenario, who: address, poa: vector<u8>) {
        ts::next_tx(sc, who);
        let mut cl = ts::take_shared<Cluster>(sc);
        failover::set_parent_poa(&mut cl, poa, ts::ctx(sc));
        ts::return_shared(cl);
    }

    fun claim_as(sc: &mut Scenario, who: address, clk: &Clock) {
        ts::next_tx(sc, who);
        let mut cl = ts::take_shared<Cluster>(sc);
        let ireg = ts::take_shared<IdRegistry>(sc);
        let treg = ts::take_shared<TrustRegistry>(sc);
        failover::claim_parent(&mut cl, &ireg, &treg, clk, ts::ctx(sc));
        ts::return_shared(treg);
        ts::return_shared(ireg);
        ts::return_shared(cl);
    }

    fun read(sc: &mut Scenario): (vector<u8>, address, address) {
        ts::next_tx(sc, ADMIN);
        let cl = ts::take_shared<Cluster>(sc);
        let poa = failover::parent_poa(&cl);
        let owner = failover::parent_poa_owner(&cl);
        let parent = failover::current_parent(&cl);
        ts::return_shared(cl);
        (poa, owner, parent)
    }

    #[test]
    fun poa_is_bound_to_the_parent_that_set_it() {
        let (mut sc, clk) = setup();
        set_poa_as(&mut sc, PARENT, OLD_POA);
        let (poa, owner, _) = read(&mut sc);
        assert!(poa == OLD_POA, 0);
        assert!(owner == PARENT, 1);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    fun takeover_clears_the_old_parents_poa() {
        // The F2 regression: before v9 this read returned OLD_POA after the
        // takeover, and followers kept connecting to the dead parent.
        let (mut sc, mut clk) = setup();
        set_poa_as(&mut sc, PARENT, OLD_POA);
        clock::increment_for_testing(&mut clk, 60_000);
        claim_as(&mut sc, CANDIDATE, &clk);
        let (poa, owner, parent) = read(&mut sc);
        assert!(parent == CANDIDATE, 0);
        assert!(vector::is_empty(&poa), 1);
        assert!(owner == @0x0, 2);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    fun new_parent_readvertises_after_takeover() {
        let (mut sc, mut clk) = setup();
        set_poa_as(&mut sc, PARENT, OLD_POA);
        clock::increment_for_testing(&mut clk, 60_000);
        claim_as(&mut sc, CANDIDATE, &clk);
        set_poa_as(&mut sc, CANDIDATE, NEW_POA);
        let (poa, owner, _) = read(&mut sc);
        assert!(poa == NEW_POA, 0);
        assert!(owner == CANDIDATE, 1);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    fun takeover_without_a_stored_poa_is_fine() {
        // clear_poa must be a no-op when nothing was advertised yet.
        let (mut sc, mut clk) = setup();
        clock::increment_for_testing(&mut clk, 60_000);
        claim_as(&mut sc, CANDIDATE, &clk);
        let (poa, _, parent) = read(&mut sc);
        assert!(parent == CANDIDATE, 0);
        assert!(vector::is_empty(&poa), 1);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = om2m_access::failover)]
    fun non_parent_cannot_set_poa() {
        let (mut sc, clk) = setup();
        set_poa_as(&mut sc, ATTACKER, NEW_POA);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = om2m_access::failover)]
    fun deposed_parent_cannot_reassert_its_poa() {
        // After losing the role, the old parent can't put its PoA back.
        let (mut sc, mut clk) = setup();
        set_poa_as(&mut sc, PARENT, OLD_POA);
        clock::increment_for_testing(&mut clk, 60_000);
        claim_as(&mut sc, CANDIDATE, &clk);
        set_poa_as(&mut sc, PARENT, OLD_POA);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }
}
