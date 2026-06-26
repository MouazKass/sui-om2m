// policy_tests.move
//
// Offline unit proofs of the policy-layer invariants PO1 and PO2 from the
// invariant spec. These mirror EXACTLY the abort codes demonstrated live
// through the DAS on the v5 package (see POLICY_EVIDENCE.md):
//
//   PO1  no policy            -> E_POLICY_MISSING   (code 1)
//   PO2  trust below min      -> E_TRUST_BELOW_MIN  (code 3)
//   PO2  op not in mask       -> E_OP_DENIED        (code 2)
//   PO2  inside blackout      -> E_IN_BLACKOUT      (code 4)
//   PO2  all conditions hold  -> returns min_trust  (positive control)
//
// policy::evaluate checks in this order: trust, then op, then blackout. The
// op/blackout tests therefore satisfy the earlier checks so the intended
// condition is the one that fires.
//
// Run with:  sui move test
//
// Requires (test-only, already present in the modules):
//   #[test_only] public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
module om2m_access::policy_tests {
    use std::string;
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};

    use om2m_access::policy::{Self, PolicyRegistry, PolicyAdminCap};

    const ADMIN: address = @0xA11CE;

    // Op-mask bits (mirror cap_token / policy semantics)
    const OP_READ:  u8 = 1;
    const OP_WRITE: u8 = 2;
    const OP_DELETE: u8 = 4;
    // Baseline policy: min_trust = 50, mask = READ|WRITE|DELETE = 7
    const BASE_MIN_TRUST: u64 = 50;
    const BASE_MASK: u8 = 7; // OP_READ | OP_WRITE | OP_DELETE

    const RES: vector<u8> = b"/in-cse/in-name/sui-protected-cnt";

    // ---- helpers -------------------------------------------------------

    fun setup(): Scenario {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut sc);
            policy::init_for_testing(ctx);
        };
        sc
    }

    fun mk_clock(sc: &mut Scenario): Clock {
        clock::create_for_testing(ts::ctx(sc))
    }

    // Install the baseline policy (min_trust=50, mask=7) on RES.
    fun set_base_policy(sc: &mut Scenario) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<PolicyAdminCap>(sc);
        let mut reg = ts::take_shared<PolicyRegistry>(sc);
        policy::set_policy(&cap, &mut reg, string::utf8(RES), BASE_MIN_TRUST, BASE_MASK);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    // ---- PO1: deny-by-default -----------------------------------------

    // No policy installed for RES -> evaluate aborts E_POLICY_MISSING (1).
    #[test]
    #[expected_failure(abort_code = 1, location = om2m_access::policy)]
    fun po1_missing_policy_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let reg = ts::take_shared<PolicyRegistry>(&mut sc);
            // valid-looking op/trust, but no policy exists -> abort 1
            let _ = policy::evaluate(&reg, &string::utf8(RES), OP_READ, 90, &clk);
            ts::return_shared(reg);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ---- PO2: the three conditions ------------------------------------

    // trust 40 < min_trust 50 -> E_TRUST_BELOW_MIN (3).
    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::policy)]
    fun po2_trust_below_min_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        set_base_policy(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let reg = ts::take_shared<PolicyRegistry>(&mut sc);
            let _ = policy::evaluate(&reg, &string::utf8(RES), OP_READ, 40, &clk);
            ts::return_shared(reg);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // op = 8 (OP_ADMIN) is NOT in mask 7; trust 90 passes -> E_OP_DENIED (2).
    #[test]
    #[expected_failure(abort_code = 2, location = om2m_access::policy)]
    fun po2_op_not_in_mask_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        set_base_policy(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let reg = ts::take_shared<PolicyRegistry>(&mut sc);
            let _ = policy::evaluate(&reg, &string::utf8(RES), 8, 90, &clk);
            ts::return_shared(reg);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // trust + op pass, but a blackout window covers 'now' -> E_IN_BLACKOUT (4).
    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::policy)]
    fun po2_in_blackout_aborts() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        set_base_policy(&mut sc);
        // add a wide blackout window [0, 10_000_000) and set clock inside it.
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<PolicyAdminCap>(&mut sc);
            let mut reg = ts::take_shared<PolicyRegistry>(&mut sc);
            policy::add_blackout(&cap, &mut reg, string::utf8(RES), 0, 10_000_000);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };
        clock::set_for_testing(&mut clk, 5_000); // inside [0, 10_000_000)
        ts::next_tx(&mut sc, ADMIN);
        {
            let reg = ts::take_shared<PolicyRegistry>(&mut sc);
            let _ = policy::evaluate(&reg, &string::utf8(RES), OP_READ, 90, &clk);
            ts::return_shared(reg);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Positive control: all conditions satisfied -> evaluate returns min_trust.
    #[test]
    fun po2_all_satisfied_returns() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc); // timestamp 0, no blackout set
        set_base_policy(&mut sc);
        ts::next_tx(&mut sc, ADMIN);
        {
            let reg = ts::take_shared<PolicyRegistry>(&mut sc);
            // op WRITE in mask, trust 90 >= 50, no blackout -> returns 50
            let mt = policy::evaluate(&reg, &string::utf8(RES), OP_WRITE, 90, &clk);
            assert!(mt == BASE_MIN_TRUST, 0);
            ts::return_shared(reg);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }
}
