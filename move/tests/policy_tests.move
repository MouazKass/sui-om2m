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
//   PO2  all conditions hold  -> min_trust reported (positive control)
//
// policy::evaluate checks in this order: policy-exists, trust, op, blackout.
// The op/blackout tests therefore satisfy the earlier checks so the intended
// condition is the one that fires.
//
// ------------------------------------------------------------------------
// v8 API MIGRATION NOTE (A5 + A6)
// ------------------------------------------------------------------------
// These tests used to call
//
//     policy::evaluate(&reg, &resource_id, op, requester_trust, &clock): u64
//
// i.e. four caller-supplied values and a u64 return. Both of the forgeable
// arguments are gone in v8:
//
//   * A5 removed `requester_trust: u64` — the score is now read inside
//     evaluate from the TrustRegistry, for the requester the receipt chain
//     carried forward.
//   * A6 removed `resource_id` and `op` as bare arguments — evaluate now
//     consumes a cap_token::TokenReceipt by value, and the only way to get
//     one is to have run identity::verify -> trust::require_min ->
//     cap_token::validate_for_use, in that order, in this transaction.
//
// So every test below has to stand up the first three steps of the chain to
// reach step 4 at all. `evaluate_as_node` does exactly that, and nothing
// more: the policy condition under test is still the only thing that
// differs between cases, and the abort codes asserted are unchanged.
//
// The trust score is now seeded in the TrustRegistry (`seed_trust`) instead
// of being passed as an argument — that substitution IS the A5 fix, and the
// PO2 trust test is correspondingly stronger than it was: it proves the
// registry value gates the decision, not that a number compares correctly.
//
// ------------------------------------------------------------------------
// REQUIRED SOURCE ADDITION (NOT owned by this workstream)
// ------------------------------------------------------------------------
// identity.move needs the same one-line test-only initializer that
// trust.move, cap_token.move and policy.move already carry:
//
//   #[test_only] public fun init_for_testing(ctx: &mut sui::tx_context::TxContext) { init(ctx) }
//
// identity::Registry is created only by identity's private `init`, and step 1
// of the chain is the only producer of an IdentityReceipt, so there is no
// test-side workaround.
//
// Run with:  sui move test

#[test_only]
module om2m_access::policy_tests {
    use std::string::{Self, String};
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};

    use om2m_access::identity::{Self, Registry as IdRegistry, AdminCap as IdAdminCap};
    use om2m_access::trust::{Self, TrustRegistry, AdminCap as TrustAdminCap};
    use om2m_access::cap_token::{Self, CapToken, IssuerCap};
    use om2m_access::policy::{Self, PolicyRegistry, PolicyAdminCap};

    const ADMIN: address = @0xA11CE;
    const NODE:  address = @0xB0B;

    // Op-mask bits (mirror cap_token / policy semantics)
    const OP_READ:  u8 = 1;
    const OP_WRITE: u8 = 2;
    const OP_ADMIN: u8 = 8;
    // Baseline policy: min_trust = 50, mask = READ|WRITE|DELETE = 7
    const BASE_MIN_TRUST: u64 = 50;
    const BASE_MASK: u8 = 7; // OP_READ | OP_WRITE | OP_DELETE
    // Token mask used where the POLICY must be the thing that denies, so the
    // token's own op check cannot pre-empt it.
    const ALL_OPS: u8 = 15;

    const RES: vector<u8> = b"/in-cse/in-name/sui-protected-cnt";
    const FAR_FUTURE: u64 = 9_000_000_000_000;

    // ---- helpers -------------------------------------------------------

    fun setup(): Scenario {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut sc);
            identity::init_for_testing(ctx);
            trust::init_for_testing(ctx);
            cap_token::init_for_testing(ctx);
            policy::init_for_testing(ctx);
        };
        sc
    }

    fun mk_clock(sc: &mut Scenario): Clock {
        clock::create_for_testing(ts::ctx(sc))
    }

    fun register_node(sc: &mut Scenario) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<IdAdminCap>(sc);
        let mut reg = ts::take_shared<IdRegistry>(sc);
        identity::register(
            &cap, &mut reg, NODE, string::utf8(b"mn-cse-1"), identity::role_mn_cse(), 0,
        );
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    // A5: the requester's trust score now lives in the registry, so the
    // "requester_trust" the old tests passed as an argument is seeded here.
    fun seed_trust(sc: &mut Scenario, clk: &Clock, score: u64) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<TrustAdminCap>(sc);
        let mut reg = ts::take_shared<TrustRegistry>(sc);
        trust::add_node(&cap, &mut reg, NODE, score, clk);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    fun mint_token(sc: &mut Scenario, ops: u8) {
        ts::next_tx(sc, ADMIN);
        let issuer = ts::take_from_sender<IssuerCap>(sc);
        cap_token::mint(
            &issuer, NODE, string::utf8(RES), ops, FAR_FUTURE, 100, ts::ctx(sc),
        );
        ts::return_to_sender(sc, issuer);
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

    // Register NODE, give it `score` in the trust registry, and mint it a
    // token on RES with `token_ops`. The policy itself is installed (or
    // deliberately not installed) by each test.
    fun world(sc: &mut Scenario, clk: &Clock, score: u64, token_ops: u8) {
        register_node(sc);
        seed_trust(sc, clk, score);
        mint_token(sc, token_ops);
    }

    // Steps 1-3 of the chain followed by step 4 (policy::evaluate), run as
    // NODE inside one transaction. Returns the PolicyReceipt's fields:
    // (requester, resource_id, requested_op, trust_score, min_trust,
    // token_uses).
    //
    // `step2_min` is the step-2 trust floor — the one trust-shaped number a
    // PTB builder still controls. Tests set it to 0 so that any trust-related
    // denial is attributable to the POLICY gate under test, not to step 2.
    fun evaluate_as_node(
        sc: &mut Scenario,
        clk: &Clock,
        op: u8,
        step2_min: u64,
    ): (address, String, u8, u64, u64, u64) {
        ts::next_tx(sc, NODE);
        let id_reg = ts::take_shared<IdRegistry>(sc);
        let t_reg = ts::take_shared<TrustRegistry>(sc);
        let p_reg = ts::take_shared<PolicyRegistry>(sc);
        let mut tok = ts::take_from_sender<CapToken>(sc);

        let r1 = identity::verify(&id_reg, ts::ctx(sc));
        let r2 = trust::require_min(r1, &t_reg, string::utf8(RES), step2_min, clk);
        let r3 = cap_token::validate_for_use(r2, &mut tok, op, clk, ts::ctx(sc));
        let r4 = policy::evaluate(r3, &p_reg, &t_reg, clk);
        let (req, res, rop, score, min_trust, uses) = policy::consume_policy_receipt(r4);

        ts::return_to_sender(sc, tok);
        ts::return_shared(p_reg);
        ts::return_shared(t_reg);
        ts::return_shared(id_reg);
        (req, res, rop, score, min_trust, uses)
    }

    // ---- PO1: deny-by-default -----------------------------------------

    // No policy installed for RES -> evaluate aborts E_POLICY_MISSING (1).
    // Everything else about the request is legitimate: NODE is registered,
    // scored 90, and holds a valid READ token on RES.
    #[test]
    #[expected_failure(abort_code = 1, location = om2m_access::policy)]
    fun po1_missing_policy_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 90, ALL_OPS);
        // deliberately NO set_base_policy

        let (_a, _b, _c, _d, _e, _f) = evaluate_as_node(&mut sc, &clk, OP_READ, 0);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // PO1 companion: removing an existing policy puts the resource back into
    // deny-by-default. (The registry is not a cache that keeps stale grants.)
    #[test]
    #[expected_failure(abort_code = 1, location = om2m_access::policy)]
    fun po1_removed_policy_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 90, ALL_OPS);
        set_base_policy(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<PolicyAdminCap>(&mut sc);
            let mut reg = ts::take_shared<PolicyRegistry>(&mut sc);
            policy::remove_policy(&cap, &mut reg, string::utf8(RES));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        let (_a, _b, _c, _d, _e, _f) = evaluate_as_node(&mut sc, &clk, OP_READ, 0);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ---- PO2: the three conditions ------------------------------------

    // Registry trust 40 < min_trust 50 -> E_TRUST_BELOW_MIN (3).
    //
    // A5: step 2's floor is set to 0, so the chain reaches step 4 with the
    // trust gate "satisfied" as far as the caller is concerned. evaluate
    // re-reads the registry (40) and denies anyway. Pre-A5 the same request
    // passed `requester_trust = 90` here and was GRANTED.
    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::policy)]
    fun po2_trust_below_min_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 40, ALL_OPS);
        set_base_policy(&mut sc);

        let (_a, _b, _c, _d, _e, _f) = evaluate_as_node(&mut sc, &clk, OP_READ, 0);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // op = 8 (OP_ADMIN) is NOT in mask 7; trust 90 passes -> E_OP_DENIED (2).
    // The token is minted with ALL_OPS so cap_token's own op check cannot be
    // the thing that fires — the denial has to come from the policy mask.
    #[test]
    #[expected_failure(abort_code = 2, location = om2m_access::policy)]
    fun po2_op_not_in_mask_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 90, ALL_OPS);
        set_base_policy(&mut sc);

        let (_a, _b, _c, _d, _e, _f) = evaluate_as_node(&mut sc, &clk, OP_ADMIN, 0);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // trust + op pass, but a blackout window covers 'now' -> E_IN_BLACKOUT (4).
    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::policy)]
    fun po2_in_blackout_aborts() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 90, ALL_OPS);
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

        let (_a, _b, _c, _d, _e, _f) = evaluate_as_node(&mut sc, &clk, OP_READ, 0);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Positive control: all conditions satisfied -> evaluate returns a
    // PolicyReceipt that reports the policy's min_trust (what the old u64
    // return value carried) alongside the rest of the decision context.
    #[test]
    fun po2_all_satisfied_returns() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc); // timestamp 0, no blackout set
        world(&mut sc, &clk, 90, ALL_OPS);
        set_base_policy(&mut sc);

        // op WRITE in mask, registry trust 90 >= 50, no blackout -> granted
        let (req, res, op, score, min_trust, uses) =
            evaluate_as_node(&mut sc, &clk, OP_WRITE, 0);
        assert!(min_trust == BASE_MIN_TRUST, 0); // the old return value
        assert!(req == NODE, 1);
        assert!(res == string::utf8(RES), 2);
        assert!(op == OP_WRITE, 3);
        assert!(score == 90, 4);                 // A5: read, not supplied
        assert!(uses == 1, 5);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Boundary positive control: trust exactly equal to min_trust is allowed
    // (the comparison is >=, not >), and a blackout window that has already
    // closed does not deny.
    #[test]
    fun po2_boundary_trust_equal_min_and_expired_blackout_allowed() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        world(&mut sc, &clk, BASE_MIN_TRUST, ALL_OPS);
        set_base_policy(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<PolicyAdminCap>(&mut sc);
            let mut reg = ts::take_shared<PolicyRegistry>(&mut sc);
            policy::add_blackout(&cap, &mut reg, string::utf8(RES), 0, 1_000);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };
        clock::set_for_testing(&mut clk, 1_000); // end_ms is exclusive

        let (_req, _res, _op, score, min_trust, _uses) =
            evaluate_as_node(&mut sc, &clk, OP_READ, 0);
        assert!(score == BASE_MIN_TRUST, 0);
        assert!(min_trust == BASE_MIN_TRUST, 1);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }
}
