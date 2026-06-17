// evolution_lifecycle_tests.move
//
// Offline proof of the evolution-layer and capability-token-lifecycle
// invariants from the invariant spec (EVO1-EVO5, EVO7, CT1-CT5).
//
// Run with:  sui move test
//
// These tests are deterministic: they SET a trust score, then assert that
// evolve() produces EXACTLY the op-mask the tier table dictates, at every
// boundary, both climbing (promotion) and falling (demotion). They also walk
// the full token lifecycle: mint -> validate -> revoke.
//
// ------------------------------------------------------------------------
// SOURCE EDIT REQUIRED (one line per module, test-only, does not change the
// published bytecode):
//
//   In identity.move, trust.move, policy.move, audit.move, cap_token.move add:
//       #[test_only] public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }
//
// That is the standard Sui pattern for testing modules whose init is private.
// ------------------------------------------------------------------------

#[test_only]
module om2m_access::evolution_lifecycle_tests {
    use std::string;
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};

    use om2m_access::trust::{Self, TrustRegistry, AdminCap as TrustAdminCap};
    use om2m_access::cap_token::{Self, CapToken, IssuerCap};
    use om2m_access::evolution;

    // Test addresses
    const ADMIN: address = @0xA11CE;     // holds caps (publisher analogue)
    const NODE:  address = @0xB0B;        // the node whose score drives evolution

    // Op-mask constants (mirror cap_token)
    const OP_READ:   u8 = 1;
    const OP_WRITE:  u8 = 2;
    const OP_DELETE: u8 = 4;
    const OP_ADMIN:  u8 = 8;

    // ---- helpers -------------------------------------------------------

    fun setup(): Scenario {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut sc);
            trust::init_for_testing(ctx);
            cap_token::init_for_testing(ctx);
        };
        sc
    }

    fun mk_clock(sc: &mut Scenario): Clock {
        clock::create_for_testing(ts::ctx(sc))
    }

    // Add NODE to the trust registry with an explicit score.
    fun seed_score(sc: &mut Scenario, clk: &Clock, score: u64) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<TrustAdminCap>(sc);
        let mut reg = ts::take_shared<TrustRegistry>(sc);
        trust::add_node(&cap, &mut reg, NODE, score, clk);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    // Mint a CapToken (READ only) to ADMIN so ADMIN can evolve it.
    // Returns nothing; the token lands in ADMIN's inventory.
    fun mint_read_token(sc: &mut Scenario, expiry_ms: u64, max_uses: u64) {
        ts::next_tx(sc, ADMIN);
        let issuer = ts::take_from_sender<IssuerCap>(sc);
        let res = string::utf8(b"/in-cse/in-name/demo-cnt");
        cap_token::mint(&issuer, ADMIN, res, OP_READ, expiry_ms, max_uses, ts::ctx(sc));
        ts::return_to_sender(sc, issuer);
    }

    // ---- EVO1 / EVO2: tier table and op-mask correctness ---------------

    // Helper that seeds a score, bootstraps a token, evolves, and returns the
    // resulting allowed_ops for assertion.
    fun evolve_at_score(score: u64, expected_ops: u8) {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        seed_score(&mut sc, &clk, score);
        mint_read_token(&mut sc, 9_000_000_000_000, 1000);

        // bootstrap + evolve
        ts::next_tx(&mut sc, ADMIN);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            evolution::bootstrap(&mut tok, &clk);
            evolution::evolve(&mut tok, &reg, NODE, &clk);
            assert!(cap_token::allowed_ops(&tok) == expected_ops, 100);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, tok);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    fun evo_tier_probation_score_10() { evolve_at_score(10, OP_READ); }            // tier 0
    #[test]
    fun evo_tier_basic_score_25()     { evolve_at_score(25, OP_READ); }            // tier 1
    #[test]
    fun evo_tier_basic_score_49()     { evolve_at_score(49, OP_READ); }            // tier 1 upper
    #[test]
    fun evo_tier_standard_score_50()  { evolve_at_score(50, OP_READ | OP_WRITE); } // tier 2 lower
    #[test]
    fun evo_tier_standard_score_74()  { evolve_at_score(74, OP_READ | OP_WRITE); } // tier 2 upper
    #[test]
    fun evo_tier_trusted_score_75()   { evolve_at_score(75, OP_READ | OP_WRITE | OP_DELETE); } // tier 3
    #[test]
    fun evo_tier_trusted_score_89()   { evolve_at_score(89, OP_READ | OP_WRITE | OP_DELETE); }
    #[test]
    fun evo_tier_custodian_score_90() { evolve_at_score(90, OP_READ | OP_WRITE | OP_DELETE | OP_ADMIN); } // tier 4
    #[test]
    fun evo_tier_custodian_score_100(){ evolve_at_score(100, OP_READ | OP_WRITE | OP_DELETE | OP_ADMIN); }

    // ---- EVO2 (demotion) + EVO3 (idempotency): full climb then strip ----

    #[test]
    fun evo_promote_then_demote_strips_ops() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);

        // Start NODE at custodian (95) so the token can reach full ops.
        seed_score(&mut sc, &clk, 95);
        mint_read_token(&mut sc, 9_000_000_000_000, 1000);

        // bootstrap + evolve up to custodian -> ops = 15
        ts::next_tx(&mut sc, ADMIN);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            evolution::bootstrap(&mut tok, &clk);
            evolution::evolve(&mut tok, &reg, NODE, &clk);
            assert!(cap_token::allowed_ops(&tok) == (OP_READ|OP_WRITE|OP_DELETE|OP_ADMIN), 200);

            // EVO3: a second evolve at the same tier is a no-op.
            evolution::evolve(&mut tok, &reg, NODE, &clk);
            assert!(cap_token::allowed_ops(&tok) == (OP_READ|OP_WRITE|OP_DELETE|OP_ADMIN), 201);

            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, tok);
        };

        // Drop NODE's score to tier 2 (standard) via decrease: 95 -> 60.
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<TrustAdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::decrease(&cap, &mut reg, NODE, 35, &clk); // 95 -> 60
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        // Evolve again -> tier 2 -> ops stripped to READ|WRITE (3). DELETE+ADMIN gone.
        ts::next_tx(&mut sc, ADMIN);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            evolution::evolve(&mut tok, &reg, NODE, &clk);
            assert!(cap_token::allowed_ops(&tok) == (OP_READ|OP_WRITE), 202);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, tok);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ---- EVO7: evolve is permissionless but truth-constrained -----------
    // A different sender (NODE itself, not the admin) calling evolve produces
    // the SAME result, because output depends only on score, not caller.

    #[test]
    fun evo_permissionless_same_result_regardless_of_caller() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        seed_score(&mut sc, &clk, 80); // tier 3
        mint_read_token(&mut sc, 9_000_000_000_000, 1000);

        // bootstrap as ADMIN
        ts::next_tx(&mut sc, ADMIN);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            evolution::bootstrap(&mut tok, &clk);
            ts::return_to_sender(&mut sc, tok);
        };
        // transfer the token to NODE so NODE can call evolve on it
        ts::next_tx(&mut sc, ADMIN);
        {
            let tok = ts::take_from_sender<CapToken>(&mut sc);
            sui::transfer::public_transfer(tok, NODE);
        };
        // NODE evolves its own token; result must match tier 3 mask.
        ts::next_tx(&mut sc, NODE);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            evolution::evolve(&mut tok, &reg, NODE, &clk);
            assert!(cap_token::allowed_ops(&tok) == (OP_READ|OP_WRITE|OP_DELETE), 300);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, tok);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ---- EVO (guard): evolve before bootstrap aborts E_NO_TIER_FIELD=2 ---

    #[test]
    #[expected_failure(abort_code = 2, location = om2m_access::evolution)]
    fun evo_without_bootstrap_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        seed_score(&mut sc, &clk, 80);
        mint_read_token(&mut sc, 9_000_000_000_000, 1000);

        ts::next_tx(&mut sc, ADMIN);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            // No bootstrap -> evolve must abort because the Tier field is absent.
            evolution::evolve(&mut tok, &reg, NODE, &clk);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, tok);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ---- CT3/CT4: token validation bounds and use-count ------------------

    #[test]
    fun ct_validate_increments_uses() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        // expiry far in future, max_uses = 3
        mint_read_token(&mut sc, 9_000_000_000_000, 3);

        ts::next_tx(&mut sc, ADMIN);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let res = string::utf8(b"/in-cse/in-name/demo-cnt");
            // three successful reads
            cap_token::validate_for_use(&mut tok, &res, OP_READ, &clk);
            cap_token::validate_for_use(&mut tok, &res, OP_READ, &clk);
            cap_token::validate_for_use(&mut tok, &res, OP_READ, &clk);
            assert!(cap_token::current_uses(&tok) == 3, 400);
            ts::return_to_sender(&mut sc, tok);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = om2m_access::cap_token)]
    fun ct_validate_exhausted_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        mint_read_token(&mut sc, 9_000_000_000_000, 1); // max_uses = 1

        ts::next_tx(&mut sc, ADMIN);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let res = string::utf8(b"/in-cse/in-name/demo-cnt");
            cap_token::validate_for_use(&mut tok, &res, OP_READ, &clk); // ok, uses 0->1
            cap_token::validate_for_use(&mut tok, &res, OP_READ, &clk); // abort E_TOKEN_EXHAUSTED=2
            ts::return_to_sender(&mut sc, tok);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::cap_token)]
    fun ct_validate_wrong_op_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        mint_read_token(&mut sc, 9_000_000_000_000, 10); // READ only

        ts::next_tx(&mut sc, ADMIN);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let res = string::utf8(b"/in-cse/in-name/demo-cnt");
            // request WRITE on a READ-only token -> E_OP_NOT_ALLOWED=4
            cap_token::validate_for_use(&mut tok, &res, OP_WRITE, &clk);
            ts::return_to_sender(&mut sc, tok);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::cap_token)]
    fun ct_validate_wrong_resource_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        mint_read_token(&mut sc, 9_000_000_000_000, 10);

        ts::next_tx(&mut sc, ADMIN);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let wrong = string::utf8(b"/in-cse/in-name/OTHER-cnt");
            // E_RESOURCE_MISMATCH=3
            cap_token::validate_for_use(&mut tok, &wrong, OP_READ, &clk);
            ts::return_to_sender(&mut sc, tok);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ---- CT5: revoke destroys the token ---------------------------------

    #[test]
    fun ct_revoke_consumes_token() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        mint_read_token(&mut sc, 9_000_000_000_000, 10);

        ts::next_tx(&mut sc, ADMIN);
        {
            let issuer = ts::take_from_sender<IssuerCap>(&mut sc);
            let tok = ts::take_from_sender<CapToken>(&mut sc);
            cap_token::revoke(&issuer, tok, ts::ctx(&mut sc)); // consumes tok
            ts::return_to_sender(&mut sc, issuer);
        };
        // After revoke, ADMIN should hold no CapToken.
        ts::next_tx(&mut sc, ADMIN);
        {
            assert!(!ts::has_most_recent_for_sender<CapToken>(&sc), 500);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }
}
