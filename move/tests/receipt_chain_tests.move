// receipt_chain_tests.move
//
// Offline unit proofs for the v8 access-path fixes A3, A4, A5, A6 and A7 —
// the "hot potato" receipt chain that replaced five independently-callable
// Move functions glued together by forgeable u64/address arguments.
//
//   A3  identity::verify          dropped its `claimed: address` argument;
//                                 the requester is tx_context::sender.
//   A4  cap_token::validate_for_use asserts signer == receipt.requester AND
//                                 token.owner == receipt.requester.
//   A5  policy::evaluate          dropped `requester_trust: u64`; it reads
//                                 trust::score_of itself.
//   A6  every step returns a receipt with NO drop/store/copy/key that the
//                                 next step consumes by value.
//   A7  audit::log and evaluator::log_denied became public(package);
//                                 external denial writes go through
//                                 evaluator::log_denied_authorized, which
//                                 requires the AuditAdminCap.
//
// Abort codes exercised here:
//   identity::E_NOT_REGISTERED      = 1
//   cap_token::E_RESOURCE_MISMATCH  = 3
//   cap_token::E_NOT_TOKEN_OWNER    = 5
//   policy::E_TRUST_BELOW_MIN       = 3
//
// ---------------------------------------------------------------------------
// A6 "impossible to construct" — why there is no runtime test for it
// ---------------------------------------------------------------------------
// Move has no `#[expected_compile_failure]` attribute, so "calling
// evaluator::decide_and_log without a PolicyReceipt does not compile" cannot
// be expressed as a test case. The property is enforced statically instead:
//
//   * PolicyReceipt / TokenReceipt / TrustReceipt / IdentityReceipt have no
//     `drop`, `store`, `copy` or `key` ability, and Move struct construction
//     is module-private, so the ONLY expression in the universe that yields a
//     PolicyReceipt is a successful `policy::evaluate` call.
//   * Writing `evaluator::decide_and_log(trail, clock)` is an arity error and
//     there is no literal, default or zero value of type PolicyReceipt to
//     supply, so the call is unwritable rather than merely rejected.
//
// What IS testable at runtime, and is tested below, is the other half of A6:
// the chain only yields a decision when run in the full correct order, the
// requester/resource binding survives every hop unchanged, and a genuinely
// low-trust requester is denied (a6_* tests).
//
// ---------------------------------------------------------------------------
// A7 TEST-FRAMEWORK LIMITATION — read before believing any result here
// ---------------------------------------------------------------------------
// A `#[test_only]` module declared under the same package address
// (om2m_access) is COMPILED INTO THE PACKAGE. `public(package)` visibility is
// therefore satisfied for this test module: it can call `audit::log` and
// `evaluator::log_denied` directly, exactly like evaluator.move can.
//
// That means the A7 fix CANNOT be proven by a runtime abort test from here —
// there is no abort to observe; an unauthorized external call is a *link
// error in the caller's package*, not a Move abort. Claiming an
// `#[expected_failure]` test for it would be a false negative.
//
// What this file does instead:
//   * documents the limitation (this comment),
//   * exercises the sanctioned replacement path
//     (a7_log_denied_authorized_writes_record) so that the AuditAdminCap gate
//     is proven to actually work and the proxy's denial trail is proven to
//     still be reachable,
//   * proves the granted path writes exactly one record through the receipt
//     chain and nothing else (a6_full_chain_in_order_grants_and_logs).
// The visibility claim itself is verified by `sui move build` of any external
// package, not by `sui move test`.
//
// ---------------------------------------------------------------------------
// REQUIRED SOURCE ADDITIONS (NOT in this workstream's ownership)
// ---------------------------------------------------------------------------
// This file cannot compile until identity.move and audit.move gain the same
// one-line test-only initializer that trust.move, cap_token.move and
// policy.move already carry:
//
//   #[test_only] public fun init_for_testing(ctx: &mut sui::tx_context::TxContext) { init(ctx) }
//
// identity::Registry and audit::AuditTrail are created only by their private
// `init`, and a Move module cannot be reopened from another file, so there is
// no test-side workaround. Every test that touches the access chain (here and
// in policy_tests.move / evolution_lifecycle_tests.move) depends on the
// identity one.
//
// Run with:  sui move test

#[test_only]
module om2m_access::receipt_chain_tests {
    use std::string::{Self, String};
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};

    use om2m_access::identity::{Self, Registry as IdRegistry, AdminCap as IdAdminCap};
    use om2m_access::trust::{Self, TrustRegistry, AdminCap as TrustAdminCap};
    use om2m_access::cap_token::{Self, CapToken, IssuerCap};
    use om2m_access::policy::{Self, PolicyRegistry, PolicyAdminCap};
    use om2m_access::audit::{Self, AuditTrail, AuditAdminCap};
    use om2m_access::evaluator;

    const ADMIN: address    = @0xA11CE; // publisher: holds all five caps
    const NODE: address     = @0xB0B;   // legitimate, registered MN-CSE
    const ATTACKER: address = @0xBAD;   // registered too, but owns no token

    const OP_READ:  u8 = 1;
    const OP_WRITE: u8 = 2;
    const BASE_MASK: u8 = 7; // READ | WRITE | DELETE

    const RES: vector<u8>       = b"/in-cse/in-name/sui-protected-cnt";
    const RES_OTHER: vector<u8> = b"/in-cse/in-name/someone-elses-cnt";

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
            audit::init_for_testing(ctx);
        };
        sc
    }

    fun mk_clock(sc: &mut Scenario): Clock {
        clock::create_for_testing(ts::ctx(sc))
    }

    fun register(sc: &mut Scenario, who: address, cse_id: vector<u8>) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<IdAdminCap>(sc);
        let mut reg = ts::take_shared<IdRegistry>(sc);
        identity::register(
            &cap, &mut reg, who, string::utf8(cse_id), identity::role_mn_cse(), 0,
        );
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    fun seed_trust(sc: &mut Scenario, clk: &Clock, who: address, score: u64) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<TrustAdminCap>(sc);
        let mut reg = ts::take_shared<TrustRegistry>(sc);
        trust::add_node(&cap, &mut reg, who, score, clk);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    fun mint_token(
        sc: &mut Scenario, owner: address, res: vector<u8>, ops: u8, max_uses: u64,
    ) {
        ts::next_tx(sc, ADMIN);
        let issuer = ts::take_from_sender<IssuerCap>(sc);
        cap_token::mint(
            &issuer, owner, string::utf8(res), ops, FAR_FUTURE, max_uses, ts::ctx(sc),
        );
        ts::return_to_sender(sc, issuer);
    }

    fun set_policy(sc: &mut Scenario, res: vector<u8>, min_trust: u64, mask: u8) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<PolicyAdminCap>(sc);
        let mut reg = ts::take_shared<PolicyRegistry>(sc);
        policy::set_policy(&cap, &mut reg, string::utf8(res), min_trust, mask);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    fun move_token(sc: &mut Scenario, from: address, to: address) {
        ts::next_tx(sc, from);
        let tok = ts::take_from_sender<CapToken>(sc);
        sui::transfer::public_transfer(tok, to);
    }

    // The whole v8 access chain, run as `who` inside ONE transaction, in the
    // only order the type system permits. Returns the PolicyReceipt's fields
    // (requester, resource_id, requested_op, trust_score, min_trust,
    // token_uses).
    //
    // `chain_res` is the resource id that enters the chain at step 2 — the
    // single place a caller still supplies it — and `min_required` is the
    // step-2 trust floor, the other value a hostile PTB builder controls.
    // Both are deliberately parameterised so the tests can lie about them.
    fun run_chain(
        sc: &mut Scenario,
        clk: &Clock,
        who: address,
        chain_res: vector<u8>,
        op: u8,
        min_required: u64,
    ): (address, String, u8, u64, u64, u64) {
        ts::next_tx(sc, who);
        let id_reg = ts::take_shared<IdRegistry>(sc);
        let t_reg = ts::take_shared<TrustRegistry>(sc);
        let p_reg = ts::take_shared<PolicyRegistry>(sc);
        let mut tok = ts::take_from_sender<CapToken>(sc);

        let r1 = identity::verify(&id_reg, ts::ctx(sc));
        let r2 = trust::require_min(r1, &t_reg, string::utf8(chain_res), min_required, clk);
        let r3 = cap_token::validate_for_use(r2, &mut tok, op, clk, ts::ctx(sc));
        let r4 = policy::evaluate(r3, &p_reg, &t_reg, clk);
        let (req, res, rop, score, min_trust, uses) = policy::consume_policy_receipt(r4);

        ts::return_to_sender(sc, tok);
        ts::return_shared(p_reg);
        ts::return_shared(t_reg);
        ts::return_shared(id_reg);
        (req, res, rop, score, min_trust, uses)
    }

    // Standard happy-path world: NODE and ATTACKER both registered, both
    // scored, policy installed on RES, NODE owns a READ|WRITE token on RES.
    fun world(sc: &mut Scenario, clk: &Clock, node_score: u64, policy_min: u64) {
        register(sc, NODE, b"mn-cse-1");
        register(sc, ATTACKER, b"mn-cse-evil");
        seed_trust(sc, clk, NODE, node_score);
        seed_trust(sc, clk, ATTACKER, node_score);
        set_policy(sc, RES, policy_min, BASE_MASK);
        mint_token(sc, NODE, RES, OP_READ | OP_WRITE, 10);
    }

    // ================= A3: identity is the signer, full stop =============

    // An unregistered signer cannot even enter the chain.
    #[test]
    #[expected_failure(abort_code = 1, location = om2m_access::identity)]
    fun a3_verify_rejects_unregistered_sender() {
        let mut sc = setup();
        register(&mut sc, NODE, b"mn-cse-1");

        ts::next_tx(&mut sc, ATTACKER);
        {
            let id_reg = ts::take_shared<IdRegistry>(&mut sc);
            // Pre-A3 the attacker passed `claimed = NODE` here and sailed
            // through. There is no such argument now -> E_NOT_REGISTERED (1).
            let r = identity::verify(&id_reg, ts::ctx(&mut sc));
            let _ = identity::consume_identity_receipt(r);
            ts::return_shared(id_reg);
        };

        ts::end(sc);
    }

    // A3 core: the receipt is bound to the ACTUAL signer, even when the
    // address the attacker would like to claim is itself registered.
    #[test]
    fun a3_receipt_always_carries_the_actual_signer() {
        let mut sc = setup();
        register(&mut sc, NODE, b"mn-cse-1");
        register(&mut sc, ATTACKER, b"mn-cse-evil");

        ts::next_tx(&mut sc, ATTACKER);
        {
            let id_reg = ts::take_shared<IdRegistry>(&mut sc);
            let r = identity::verify(&id_reg, ts::ctx(&mut sc));
            assert!(identity::identity_receipt_requester(&r) == ATTACKER, 0);
            assert!(identity::identity_receipt_requester(&r) != NODE, 1);
            let who = identity::consume_identity_receipt(r);
            assert!(who == ATTACKER, 2);
            ts::return_shared(id_reg);
        };

        ts::end(sc);
    }

    // Positive control: a registered signer gets a receipt bound to itself.
    #[test]
    fun a3_verify_accepts_registered_sender() {
        let mut sc = setup();
        register(&mut sc, NODE, b"mn-cse-1");

        ts::next_tx(&mut sc, NODE);
        {
            let id_reg = ts::take_shared<IdRegistry>(&mut sc);
            assert!(identity::is_registered(&id_reg, NODE), 0);
            let r = identity::verify(&id_reg, ts::ctx(&mut sc));
            let who = identity::consume_identity_receipt(r);
            assert!(who == NODE, 1);
            ts::return_shared(id_reg);
        };

        ts::end(sc);
    }

    // ================= A4: token ownership is enforced ===================

    // ATTACKER gets physical custody of NODE's token (a plain object
    // transfer) and runs the chain as itself. token.owner is still NODE, so
    // validation fails closed -> E_NOT_TOKEN_OWNER (5).
    #[test]
    #[expected_failure(abort_code = 5, location = om2m_access::cap_token)]
    fun a4_non_owner_cannot_use_a_transferred_token() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 80, 50);

        move_token(&mut sc, NODE, ATTACKER);

        let (_a, _b, _c, _d, _e, _f) =
            run_chain(&mut sc, &clk, ATTACKER, RES, OP_READ, 50);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Positive control: the real owner validates its own token and the use
    // counter ticks.
    #[test]
    fun a4_owner_can_use_its_own_token() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 80, 50);

        let (req, _res, op, _score, _min, uses) =
            run_chain(&mut sc, &clk, NODE, RES, OP_READ, 50);
        assert!(req == NODE, 0);
        assert!(op == OP_READ, 1);
        assert!(uses == 1, 2);

        ts::next_tx(&mut sc, NODE);
        {
            let tok = ts::take_from_sender<CapToken>(&mut sc);
            assert!(cap_token::owner(&tok) == NODE, 3);
            assert!(cap_token::current_uses(&tok) == 1, 4);
            ts::return_to_sender(&mut sc, tok);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ================= A5: the trust score is read, not received =========

    // The only trust-related number a PTB builder still controls is step 2's
    // `min_required`. Set it to 10 so the trust gate "passes" with a real
    // score of 40 — policy::evaluate then re-reads the registry and compares
    // the REAL 40 against min_trust 50 -> E_TRUST_BELOW_MIN (3).
    //
    // Pre-A5 the same PTB passed `requester_trust = 100` to evaluate and was
    // granted.
    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::policy)]
    fun a5_forged_low_min_required_cannot_fake_a_trust_score() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 40, 50); // real score 40, policy wants 50

        let (_a, _b, _c, _d, _e, _f) =
            run_chain(&mut sc, &clk, NODE, RES, OP_READ, 10); // lie: min 10

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // A5 core: the PolicyReceipt reports the registry's number verbatim.
    #[test]
    fun a5_policy_receipt_reports_the_registry_score() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 80, 50);

        let (req, res, op, score, min_trust, uses) =
            run_chain(&mut sc, &clk, NODE, RES, OP_READ, 0);
        assert!(req == NODE, 0);
        assert!(res == string::utf8(RES), 1);
        assert!(op == OP_READ, 2);
        assert!(score == 80, 3);      // the registry value, not an argument
        assert!(min_trust == 50, 4);
        assert!(uses == 1, 5);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // A5, the stronger form: change the registry and the evaluated score
    // changes with it. Nothing the caller passes can decouple the two.
    #[test]
    fun a5_evaluated_score_tracks_registry_changes() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 80, 50);

        let (_r1, _s1, _o1, score_before, _m1, _u1) =
            run_chain(&mut sc, &clk, NODE, RES, OP_READ, 0);
        assert!(score_before == 80, 0);

        // A12 rate limit: a write needs >= MIN_INTERVAL_MS (60s) since the
        // entry's last update and a delta <= MAX_DELTA (15).
        clock::set_for_testing(&mut clk, 60_000);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<TrustAdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::decrease_guarded(&cap, &mut reg, NODE, 15, &clk, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        let (_r2, _s2, _o2, score_after, _m2, _u2) =
            run_chain(&mut sc, &clk, NODE, RES, OP_READ, 0);
        assert!(score_after == 65, 1);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ================= A6: the chain, in order, or not at all ============

    // The full five-command PTB shape, executed in one transaction, ending in
    // exactly one GRANTED audit record.
    #[test]
    fun a6_full_chain_in_order_grants_and_logs() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 80, 50);

        ts::next_tx(&mut sc, NODE);
        {
            let id_reg = ts::take_shared<IdRegistry>(&mut sc);
            let t_reg = ts::take_shared<TrustRegistry>(&mut sc);
            let p_reg = ts::take_shared<PolicyRegistry>(&mut sc);
            let mut trail = ts::take_shared<AuditTrail>(&mut sc);
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);

            assert!(audit::count(&trail) == 0, 0);

            let r1 = identity::verify(&id_reg, ts::ctx(&mut sc));
            let r2 = trust::require_min(r1, &t_reg, string::utf8(RES), 50, &clk);
            let r3 = cap_token::validate_for_use(r2, &mut tok, OP_WRITE, &clk, ts::ctx(&mut sc));
            let r4 = policy::evaluate(r3, &p_reg, &t_reg, &clk);
            evaluator::decide_and_log(r4, &mut trail, &clk);

            // Holding a PolicyReceipt WAS the decision; decide_and_log only
            // records it. Exactly one record, written atomically.
            assert!(audit::count(&trail) == 1, 1);
            assert!(cap_token::current_uses(&tok) == 1, 2);

            ts::return_to_sender(&mut sc, tok);
            ts::return_shared(trail);
            ts::return_shared(p_reg);
            ts::return_shared(t_reg);
            ts::return_shared(id_reg);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // A6: the requester/resource/op binding established at step 1-2 survives
    // every hop unchanged — there is no point in the chain at which a value
    // can be swapped for a different one.
    #[test]
    fun a6_receipt_binding_survives_every_hop() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 80, 50);
        let want_res = string::utf8(RES);

        ts::next_tx(&mut sc, NODE);
        {
            let id_reg = ts::take_shared<IdRegistry>(&mut sc);
            let t_reg = ts::take_shared<TrustRegistry>(&mut sc);
            let p_reg = ts::take_shared<PolicyRegistry>(&mut sc);
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);

            // step 1
            let r1 = identity::verify(&id_reg, ts::ctx(&mut sc));
            assert!(identity::identity_receipt_requester(&r1) == NODE, 0);

            // step 2 — resource enters the chain here, once
            let r2 = trust::require_min(r1, &t_reg, string::utf8(RES), 50, &clk);
            assert!(trust::trust_receipt_requester(&r2) == NODE, 1);
            assert!(trust::trust_receipt_resource(&r2) == &want_res, 2);

            // step 3
            let r3 = cap_token::validate_for_use(r2, &mut tok, OP_READ, &clk, ts::ctx(&mut sc));
            assert!(cap_token::token_receipt_requester(&r3) == NODE, 3);
            assert!(cap_token::token_receipt_resource(&r3) == &want_res, 4);
            assert!(cap_token::token_receipt_op(&r3) == OP_READ, 5);
            assert!(cap_token::token_receipt_uses(&r3) == 1, 6);

            // step 4
            let r4 = policy::evaluate(r3, &p_reg, &t_reg, &clk);
            assert!(policy::policy_receipt_requester(&r4) == NODE, 7);
            assert!(policy::policy_receipt_resource(&r4) == &want_res, 8);
            assert!(policy::policy_receipt_op(&r4) == OP_READ, 9);
            assert!(policy::policy_receipt_trust(&r4) == 80, 10);
            assert!(policy::policy_receipt_min_trust(&r4) == 50, 11);
            assert!(policy::policy_receipt_token_uses(&r4) == 1, 12);

            let (_a, _b, _c, _d, _e, _f) = policy::consume_policy_receipt(r4);

            ts::return_to_sender(&mut sc, tok);
            ts::return_shared(p_reg);
            ts::return_shared(t_reg);
            ts::return_shared(id_reg);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // A6: a genuinely low-trust requester, running the chain correctly and in
    // full order, is DENIED. The chain is not a rubber stamp.
    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::policy)]
    fun a6_low_trust_requester_is_denied_by_the_chain() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 20, 50); // real score 20, policy wants 50

        // step 2's floor is set to 0 so the chain reaches step 4 and the
        // denial is attributable to the policy gate, not the trust gate.
        let (_a, _b, _c, _d, _e, _f) =
            run_chain(&mut sc, &clk, NODE, RES, OP_READ, 0);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // A6: the resource cannot be retargeted mid-chain. The caller declares
    // RES_OTHER at step 2; step 3 compares the token against the RECEIPT (not
    // against a second, independently-supplied argument) and fails closed
    // -> E_RESOURCE_MISMATCH (3).
    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::cap_token)]
    fun a6_resource_cannot_be_retargeted_mid_chain() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        world(&mut sc, &clk, 80, 50);
        set_policy(&mut sc, RES_OTHER, 50, BASE_MASK); // policy exists, so the
                                                       // mismatch is the only
                                                       // possible failure
        let (_a, _b, _c, _d, _e, _f) =
            run_chain(&mut sc, &clk, NODE, RES_OTHER, OP_READ, 50);

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ================= A7: who may write the audit trail ================
    //
    // See the module header for why the "external caller is rejected" half of
    // A7 is a compile-time property that this test module — being inside the
    // package — structurally cannot observe.

    // The sanctioned replacement for the now-package-private
    // evaluator::log_denied: AuditAdminCap-gated, so the IN-CSE proxy keeps
    // its out-of-band denial trail and nobody else gets one.
    #[test]
    fun a7_log_denied_authorized_writes_record() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AuditAdminCap>(&mut sc);
            let mut trail = ts::take_shared<AuditTrail>(&mut sc);
            assert!(audit::count(&trail) == 0, 0);
            evaluator::log_denied_authorized(
                &cap, &mut trail, ATTACKER, string::utf8(RES), OP_READ, 12, &clk,
            );
            assert!(audit::count(&trail) == 1, 1);
            ts::return_shared(trail);
            ts::return_to_sender(&mut sc, cap);
        };

        // The cap is a real object held by the publisher: an address that
        // does not hold one cannot even assemble the call, which is why
        // there is no #[expected_failure] counterpart to this test.
        ts::next_tx(&mut sc, ATTACKER);
        {
            assert!(!ts::has_most_recent_for_sender<AuditAdminCap>(&sc), 2);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }
}
