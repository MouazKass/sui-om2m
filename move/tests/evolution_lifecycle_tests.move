// evolution_lifecycle_tests.move
//
// Offline proof of the evolution-layer and capability-token-lifecycle
// invariants from the invariant spec (EVO1-EVO5, EVO7, CT1-CT5), plus the
// v8 A9 fix (evolve reads the SIGNER's own trust score).
//
// Run with:  sui move test
//
// These tests are deterministic: they SET a trust score, then assert that
// evolve() produces EXACTLY the op-mask the tier table dictates, at every
// boundary, both climbing (promotion) and falling (demotion). They also walk
// the full token lifecycle: mint -> validate -> revoke.
//
// ------------------------------------------------------------------------
// v8 API MIGRATION NOTES
// ------------------------------------------------------------------------
// A9  evolution::evolve was
//
//         evolve(token, trust_reg, node_addr: address, clock)
//
//     and is now
//
//         evolve(token, trust_reg, clock, ctx: &TxContext)
//
//     The caller-supplied `node_addr` is gone: the score is read for
//     tx_context::sender(ctx), and the signer must be the address the token
//     was issued to (E_NOT_TOKEN_OWNER = 3). Every tier-table test therefore
//     mints the token TO the scored node and evolves AS that node — the tier
//     table itself is unchanged, so the assertions are identical.
//
//     Consequence for the old `evo_permissionless_same_result_regardless_of_caller`
//     test: the property it asserted (evolve is permissionless; the result
//     depends only on the score, not the caller) was DELIBERATELY removed by
//     A9. That test has been replaced by the a9_* pair below, which prove the
//     property that replaced it. It was not deleted silently and it was not
//     weakened — the feature changed.
//
// A6  cap_token::validate_for_use was
//
//         validate_for_use(token, resource_id: &String, op, clock)
//
//     and is now
//
//         validate_for_use(TrustReceipt, token, op, clock, ctx): TokenReceipt
//
//     The resource id is no longer a bare argument; it arrives inside the
//     receipt that identity::verify -> trust::require_min produced. The CT3/
//     CT4 tests therefore drive the first two chain steps via `validate_once`
//     before reaching the token. The abort codes asserted are unchanged
//     (E_TOKEN_EXPIRED=1, E_TOKEN_EXHAUSTED=2, E_RESOURCE_MISMATCH=3,
//     E_OP_NOT_ALLOWED=4).
//
// A12 trust::decrease now rejects a delta > MAX_DELTA (15) and a write less
//     than MIN_INTERVAL_MS (60_000) after the entry's last update. The old
//     demotion test did 95 -> 60 in a single 35-point write at clock 0; it
//     now does two legal 15-point writes with the clock advanced between
//     them (95 -> 80 -> 65). 65 is still tier STANDARD, so the asserted
//     op-mask is unchanged.
//
// A11 `attach_sub_capability` / `SubCapability` / `SubCapabilityAttached`
//     were deleted from evolution.move. This file never exercised them, so
//     no test was removed on that account.
//
// ------------------------------------------------------------------------
// REQUIRED SOURCE ADDITION (NOT owned by this workstream)
// ------------------------------------------------------------------------
// identity.move needs the one-line test-only initializer that trust.move,
// cap_token.move and policy.move already carry:
//
//   #[test_only] public fun init_for_testing(ctx: &mut sui::tx_context::TxContext) { init(ctx) }
//
// It is needed because cap_token::validate_for_use is no longer independently
// callable — reaching it requires an IdentityReceipt, and identity::Registry
// is created only by identity's private `init`.
// ------------------------------------------------------------------------

#[test_only]
module om2m_access::evolution_lifecycle_tests {
    use std::string;
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};

    use om2m_access::identity::{Self, Registry as IdRegistry, AdminCap as IdAdminCap};
    use om2m_access::trust::{Self, TrustRegistry, AdminCap as TrustAdminCap};
    use om2m_access::cap_token::{Self, CapToken, IssuerCap};
    use om2m_access::evolution;

    // Test addresses
    const ADMIN: address    = @0xA11CE;  // holds caps (publisher analogue)
    const NODE:  address    = @0xB0B;    // the node whose score drives evolution
    const ATTACKER: address = @0xBAD;    // low-trust node that wants NODE's tier

    // Op-mask constants (mirror cap_token)
    const OP_READ:   u8 = 1;
    const OP_WRITE:  u8 = 2;
    const OP_DELETE: u8 = 4;
    const OP_ADMIN:  u8 = 8;

    const RES: vector<u8> = b"/in-cse/in-name/demo-cnt";
    const FAR_FUTURE: u64 = 9_000_000_000_000;

    // ---- helpers -------------------------------------------------------

    fun setup(): Scenario {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut sc);
            identity::init_for_testing(ctx);
            trust::init_for_testing(ctx);
            cap_token::init_for_testing(ctx);
        };
        sc
    }

    fun mk_clock(sc: &mut Scenario): Clock {
        clock::create_for_testing(ts::ctx(sc))
    }

    // Register `who` in the identity registry (needed to enter step 1 of the
    // chain, which the CT validation tests must now do).
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

    // Add `who` to the trust registry with an explicit score.
    fun seed_score(sc: &mut Scenario, clk: &Clock, who: address, score: u64) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<TrustAdminCap>(sc);
        let mut reg = ts::take_shared<TrustRegistry>(sc);
        trust::add_node(&cap, &mut reg, who, score, clk);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    // Mint a CapToken on RES to `owner`. A9: the token's recorded owner is
    // what evolve() checks against the signer, so the token has to be minted
    // to whoever is going to evolve it.
    fun mint_token(
        sc: &mut Scenario, owner: address, ops: u8, expiry_ms: u64, max_uses: u64,
    ) {
        ts::next_tx(sc, ADMIN);
        let issuer = ts::take_from_sender<IssuerCap>(sc);
        cap_token::mint(
            &issuer, owner, string::utf8(RES), ops, expiry_ms, max_uses, ts::ctx(sc),
        );
        ts::return_to_sender(sc, issuer);
    }

    // A single trip through chain steps 1-3 against `tok`, inside the
    // caller's already-open transaction. The step-2 trust floor is 0 so the
    // only thing that can abort is the token check under test.
    //
    // The shared registries are passed in by reference rather than taken
    // here: sui::test_scenario will not hand out the same shared object twice
    // within one transaction, and ct_validate_increments_uses deliberately
    // validates three times in a single transaction.
    fun validate_once(
        sc: &mut Scenario,
        clk: &Clock,
        id_reg: &IdRegistry,
        t_reg: &TrustRegistry,
        chain_res: vector<u8>,
        op: u8,
        tok: &mut CapToken,
    ) {
        let r1 = identity::verify(id_reg, ts::ctx(sc));
        let r2 = trust::require_min(r1, t_reg, string::utf8(chain_res), 0, clk);
        let r3 = cap_token::validate_for_use(r2, tok, op, clk, ts::ctx(sc));
        let (_rq, _rs, _ro, _tid, _tu) = cap_token::consume_token_receipt(r3);
    }

    // ---- EVO1 / EVO2: tier table and op-mask correctness ---------------

    // Seeds NODE's score, mints NODE a READ-only token, bootstraps, evolves
    // AS NODE, and asserts the resulting allowed_ops.
    fun evolve_at_score(score: u64, expected_ops: u8) {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        seed_score(&mut sc, &clk, NODE, score);
        mint_token(&mut sc, NODE, OP_READ, FAR_FUTURE, 1000);

        // bootstrap + evolve, signed by the token's owner
        ts::next_tx(&mut sc, NODE);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            evolution::bootstrap(&mut tok, &clk);
            evolution::evolve(&mut tok, &reg, &clk, ts::ctx(&mut sc));
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
        let mut clk = mk_clock(&mut sc);

        // Start NODE at custodian (95) so the token can reach full ops.
        seed_score(&mut sc, &clk, NODE, 95);
        mint_token(&mut sc, NODE, OP_READ, FAR_FUTURE, 1000);

        // bootstrap + evolve up to custodian -> ops = 15
        ts::next_tx(&mut sc, NODE);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            evolution::bootstrap(&mut tok, &clk);
            evolution::evolve(&mut tok, &reg, &clk, ts::ctx(&mut sc));
            assert!(cap_token::allowed_ops(&tok) == (OP_READ|OP_WRITE|OP_DELETE|OP_ADMIN), 200);

            // EVO3: a second evolve at the same tier is a no-op.
            evolution::evolve(&mut tok, &reg, &clk, ts::ctx(&mut sc));
            assert!(cap_token::allowed_ops(&tok) == (OP_READ|OP_WRITE|OP_DELETE|OP_ADMIN), 201);

            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, tok);
        };

        // Drop NODE's score from custodian to tier 2 (standard): 95 -> 65.
        // A12 caps a single write at MAX_DELTA (15) and requires
        // MIN_INTERVAL_MS (60_000) between writes on the same entry, so this
        // is two legal writes rather than the old single 35-point one.
        clock::set_for_testing(&mut clk, 60_000);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<TrustAdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::decrease(&cap, &mut reg, NODE, 15, &clk); // 95 -> 80
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };
        clock::set_for_testing(&mut clk, 120_000);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<TrustAdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::decrease(&cap, &mut reg, NODE, 15, &clk); // 80 -> 65
            assert!(trust::score_of(&reg, NODE, &clk) == 65, 202);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        // Evolve again -> tier 2 -> ops stripped to READ|WRITE (3). DELETE+ADMIN gone.
        ts::next_tx(&mut sc, NODE);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            evolution::evolve(&mut tok, &reg, &clk, ts::ctx(&mut sc));
            assert!(cap_token::allowed_ops(&tok) == (OP_READ|OP_WRITE), 203);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, tok);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ---- A9: evolve uses the SIGNER's own score, on the signer's token ---
    //
    // Replaces the pre-v8 `evo_permissionless_same_result_regardless_of_caller`
    // test, whose property (caller-independence) A9 intentionally removed.

    // Negative: ATTACKER (real score 10) holds its own token and wants NODE's
    // custodian tier. There is no longer an address argument to point at
    // NODE, and the score comes from tx_context::sender, so ATTACKER gets
    // exactly tier PROBATION -> OP_READ only. Pre-A9 the same call passed
    // `node_addr = NODE` and promoted the token to ops = 15.
    #[test]
    fun a9_evolve_cannot_borrow_another_nodes_score() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        seed_score(&mut sc, &clk, NODE, 95);     // the score the attacker wants
        seed_score(&mut sc, &clk, ATTACKER, 10); // the score it actually has
        mint_token(&mut sc, ATTACKER, OP_READ, FAR_FUTURE, 1000);

        ts::next_tx(&mut sc, ATTACKER);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            assert!(trust::score_of(&reg, NODE, &clk) == 95, 300);
            evolution::bootstrap(&mut tok, &clk);
            evolution::evolve(&mut tok, &reg, &clk, ts::ctx(&mut sc));
            // probation, NOT custodian
            assert!(cap_token::allowed_ops(&tok) == OP_READ, 301);
            assert!(cap_token::allowed_ops(&tok) != (OP_READ|OP_WRITE|OP_DELETE|OP_ADMIN), 302);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, tok);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Negative: physical custody of someone else's token is not enough.
    // ATTACKER receives NODE's token by plain object transfer; token.owner is
    // still NODE, so evolve fails closed -> E_NOT_TOKEN_OWNER (3).
    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::evolution)]
    fun a9_non_owner_cannot_evolve_a_transferred_token() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        seed_score(&mut sc, &clk, NODE, 95);
        seed_score(&mut sc, &clk, ATTACKER, 95); // equally trusted: not the point
        mint_token(&mut sc, NODE, OP_READ, FAR_FUTURE, 1000);

        ts::next_tx(&mut sc, NODE);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            evolution::bootstrap(&mut tok, &clk);
            sui::transfer::public_transfer(tok, ATTACKER);
        };

        ts::next_tx(&mut sc, ATTACKER);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            evolution::evolve(&mut tok, &reg, &clk, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, tok);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Positive control: the legitimate owner evolving its own token gets the
    // tier its own score earns.
    #[test]
    fun a9_owner_evolves_with_its_own_score() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        seed_score(&mut sc, &clk, NODE, 80); // tier 3 (trusted)
        mint_token(&mut sc, NODE, OP_READ, FAR_FUTURE, 1000);

        ts::next_tx(&mut sc, NODE);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            evolution::bootstrap(&mut tok, &clk);
            evolution::evolve(&mut tok, &reg, &clk, ts::ctx(&mut sc));
            assert!(cap_token::allowed_ops(&tok) == (OP_READ|OP_WRITE|OP_DELETE), 310);
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
        seed_score(&mut sc, &clk, NODE, 80);
        mint_token(&mut sc, NODE, OP_READ, FAR_FUTURE, 1000);

        ts::next_tx(&mut sc, NODE);
        {
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            // No bootstrap -> evolve must abort because the Tier field is absent.
            evolution::evolve(&mut tok, &reg, &clk, ts::ctx(&mut sc));
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
        register(&mut sc, NODE, b"mn-cse-1");
        seed_score(&mut sc, &clk, NODE, 50);
        // expiry far in future, max_uses = 3
        mint_token(&mut sc, NODE, OP_READ, FAR_FUTURE, 3);

        ts::next_tx(&mut sc, NODE);
        {
            let id_reg = ts::take_shared<IdRegistry>(&mut sc);
            let t_reg = ts::take_shared<TrustRegistry>(&mut sc);
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            // three successful reads, each a full step 1 -> 3 trip
            validate_once(&mut sc, &clk, &id_reg, &t_reg, RES, OP_READ, &mut tok);
            validate_once(&mut sc, &clk, &id_reg, &t_reg, RES, OP_READ, &mut tok);
            validate_once(&mut sc, &clk, &id_reg, &t_reg, RES, OP_READ, &mut tok);
            assert!(cap_token::current_uses(&tok) == 3, 400);
            ts::return_to_sender(&mut sc, tok);
            ts::return_shared(t_reg);
            ts::return_shared(id_reg);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = om2m_access::cap_token)]
    fun ct_validate_exhausted_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        register(&mut sc, NODE, b"mn-cse-1");
        seed_score(&mut sc, &clk, NODE, 50);
        mint_token(&mut sc, NODE, OP_READ, FAR_FUTURE, 1); // max_uses = 1

        ts::next_tx(&mut sc, NODE);
        {
            let id_reg = ts::take_shared<IdRegistry>(&mut sc);
            let t_reg = ts::take_shared<TrustRegistry>(&mut sc);
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            validate_once(&mut sc, &clk, &id_reg, &t_reg, RES, OP_READ, &mut tok); // uses 0->1
            validate_once(&mut sc, &clk, &id_reg, &t_reg, RES, OP_READ, &mut tok); // E_TOKEN_EXHAUSTED=2
            ts::return_to_sender(&mut sc, tok);
            ts::return_shared(t_reg);
            ts::return_shared(id_reg);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::cap_token)]
    fun ct_validate_wrong_op_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        register(&mut sc, NODE, b"mn-cse-1");
        seed_score(&mut sc, &clk, NODE, 50);
        mint_token(&mut sc, NODE, OP_READ, FAR_FUTURE, 10); // READ only

        ts::next_tx(&mut sc, NODE);
        {
            let id_reg = ts::take_shared<IdRegistry>(&mut sc);
            let t_reg = ts::take_shared<TrustRegistry>(&mut sc);
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            // request WRITE on a READ-only token -> E_OP_NOT_ALLOWED=4
            validate_once(&mut sc, &clk, &id_reg, &t_reg, RES, OP_WRITE, &mut tok);
            ts::return_to_sender(&mut sc, tok);
            ts::return_shared(t_reg);
            ts::return_shared(id_reg);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::cap_token)]
    fun ct_validate_wrong_resource_aborts() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        register(&mut sc, NODE, b"mn-cse-1");
        seed_score(&mut sc, &clk, NODE, 50);
        mint_token(&mut sc, NODE, OP_READ, FAR_FUTURE, 10);

        ts::next_tx(&mut sc, NODE);
        {
            let id_reg = ts::take_shared<IdRegistry>(&mut sc);
            let t_reg = ts::take_shared<TrustRegistry>(&mut sc);
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            // the chain declares a different resource than the token's
            // -> E_RESOURCE_MISMATCH=3
            validate_once(
                &mut sc, &clk, &id_reg, &t_reg,
                b"/in-cse/in-name/OTHER-cnt", OP_READ, &mut tok,
            );
            ts::return_to_sender(&mut sc, tok);
            ts::return_shared(t_reg);
            ts::return_shared(id_reg);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // CT: absolute expiry is enforced against the Clock -> E_TOKEN_EXPIRED=1.
    #[test]
    #[expected_failure(abort_code = 1, location = om2m_access::cap_token)]
    fun ct_validate_expired_aborts() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        register(&mut sc, NODE, b"mn-cse-1");
        seed_score(&mut sc, &clk, NODE, 50);
        mint_token(&mut sc, NODE, OP_READ, 1_000, 10); // expires at t=1000

        clock::set_for_testing(&mut clk, 2_000);
        ts::next_tx(&mut sc, NODE);
        {
            let id_reg = ts::take_shared<IdRegistry>(&mut sc);
            let t_reg = ts::take_shared<TrustRegistry>(&mut sc);
            let mut tok = ts::take_from_sender<CapToken>(&mut sc);
            validate_once(&mut sc, &clk, &id_reg, &t_reg, RES, OP_READ, &mut tok);
            ts::return_to_sender(&mut sc, tok);
            ts::return_shared(t_reg);
            ts::return_shared(id_reg);
        };
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ---- CT5: revoke destroys the token ---------------------------------

    #[test]
    fun ct_revoke_consumes_token() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        // minted to ADMIN, who also holds the IssuerCap, so one tx can revoke
        mint_token(&mut sc, ADMIN, OP_READ, FAR_FUTURE, 10);

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
