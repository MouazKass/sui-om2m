// admin_cap_validity_tests.move
//
// Offline unit proofs for the v8 AdminCap-hardening fixes A1, A2 and A8 in
// trust.move. These complement trust_revocation_tests.move (which covers the
// original TR7 scoring path) by attacking the *other* cap-gated entry points
// that used to accept `_admin: &AdminCap` and never look at it.
//
//   A1  add_node                 ignored the cap  -> a revoked cap could
//                                create trust entries.
//   A2  bootstrap_valid_caps     ignored the cap  -> a revoked cap could
//                                re-register itself and undo its revocation.
//   A8  grant_admin /            ignored the cap AND never inserted the new
//       grant_admin_registered   cap id into the validity set -> a revoked
//                                admin could launder its lost authority into
//                                a freshly minted cap that TR7 could never
//                                revoke.
//
// All three now call trust::assert_cap_valid first, and both grant paths go
// through the single private mint_and_register, so every minted cap is
// revocable.
//
//   trust error codes used here:  E_CAP_REVOKED = 5
//
// Enforcement note: on v8 `trust::init` registers the genesis AdminCap in the
// validity set and writes the BOOTSTRAPPED_KEY marker in the same
// transaction, so assert_cap_valid is fail-CLOSED from genesis. These tests
// therefore do NOT need an explicit bootstrap_valid_caps call first (unlike
// trust_revocation_tests.move, which was written against the old fail-open
// window).
//
// Run with:  sui move test

#[test_only]
module om2m_access::admin_cap_validity_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};
    use sui::object::{Self, ID};

    use om2m_access::trust::{Self, TrustRegistry, AdminCap};

    const ADMIN: address    = @0xA11CE;   // publisher / genesis cap holder
    const ATTACKER: address = @0xBAD;     // holds a cap that gets revoked
    const GRANTEE: address  = @0xC0FFEE;  // innocent third party
    const NODE: address     = @0xB0B;     // node the attacker wants to write
    const NODE2: address    = @0xB0B2;

    // ---- helpers -------------------------------------------------------

    fun setup(): Scenario {
        let mut sc = ts::begin(ADMIN);
        {
            trust::init_for_testing(ts::ctx(&mut sc));
        };
        sc
    }

    fun mk_clock(sc: &mut Scenario): Clock {
        clock::create_for_testing(ts::ctx(sc))
    }

    // ADMIN mints a registered AdminCap for `recipient` via the TR7 path.
    fun grant_registered(sc: &mut Scenario, recipient: address) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let mut reg = ts::take_shared<TrustRegistry>(sc);
        trust::grant_admin_registered(&cap, &mut reg, recipient, ts::ctx(sc));
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    // ADMIN mints a cap for `recipient` via the OTHER (A8) grant path.
    fun grant_plain(sc: &mut Scenario, recipient: address) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let mut reg = ts::take_shared<TrustRegistry>(sc);
        trust::grant_admin(&cap, &mut reg, recipient, ts::ctx(sc));
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    // Read the id of the AdminCap currently held by `holder`.
    fun cap_id_of(sc: &mut Scenario, holder: address): ID {
        ts::next_tx(sc, holder);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let id = object::id(&cap);
        ts::return_to_sender(sc, cap);
        id
    }

    // ADMIN revokes `cap_id`.
    fun revoke(sc: &mut Scenario, cap_id: ID) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let mut reg = ts::take_shared<TrustRegistry>(sc);
        trust::revoke_admin(&cap, &mut reg, cap_id, ts::ctx(sc));
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    // Give ATTACKER a cap and immediately revoke it.
    fun arm_revoked_attacker(sc: &mut Scenario) {
        grant_registered(sc, ATTACKER);
        let bad = cap_id_of(sc, ATTACKER);
        revoke(sc, bad);
    }

    // ================= A1: add_node is cap-gated =========================

    // A revoked AdminCap can no longer create trust entries.
    #[test]
    #[expected_failure(abort_code = 5, location = om2m_access::trust)]
    fun a1_revoked_cap_cannot_add_node() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        arm_revoked_attacker(&mut sc);

        ts::next_tx(&mut sc, ATTACKER);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            // Pre-A1 this inserted NODE with a score of the attacker's
            // choosing. Now -> E_CAP_REVOKED (5).
            trust::add_node(&cap, &mut reg, NODE, 100, &clk);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Positive control: the genesis cap still works.
    #[test]
    fun a1_valid_cap_can_add_node() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::add_node(&cap, &mut reg, NODE, 50, &clk);
            assert!(trust::has_node(&reg, NODE), 0);
            assert!(trust::score_of(&reg, NODE, &clk) == 50, 1);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ================= A2: bootstrap_valid_caps is cap-gated =============

    // A revoked cap cannot re-register itself (undo its own revocation).
    #[test]
    #[expected_failure(abort_code = 5, location = om2m_access::trust)]
    fun a2_revoked_cap_cannot_rebootstrap_itself() {
        let mut sc = setup();
        arm_revoked_attacker(&mut sc);

        ts::next_tx(&mut sc, ATTACKER);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            let ids = vector[ object::id(&cap) ];
            // Pre-A2 this put the attacker's own revoked id straight back
            // into the validity set. Now -> E_CAP_REVOKED (5).
            trust::bootstrap_valid_caps(&cap, &mut reg, ids, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        ts::end(sc);
    }

    // Positive control: a valid cap may still (idempotently) bootstrap.
    #[test]
    fun a2_valid_cap_can_bootstrap() {
        let mut sc = setup();

        let genesis = cap_id_of(&mut sc, ADMIN);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            let ids = vector[ genesis ];
            trust::bootstrap_valid_caps(&cap, &mut reg, ids, ts::ctx(&mut sc));
            assert!(trust::is_cap_valid(&reg, genesis), 0);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        ts::end(sc);
    }

    // ================= A8: both grant paths gated + registering ==========

    // A revoked cap cannot mint a fresh cap for a third party.
    #[test]
    #[expected_failure(abort_code = 5, location = om2m_access::trust)]
    fun a8_revoked_cap_cannot_grant_admin_registered() {
        let mut sc = setup();
        arm_revoked_attacker(&mut sc);

        ts::next_tx(&mut sc, ATTACKER);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::grant_admin_registered(&cap, &mut reg, GRANTEE, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        ts::end(sc);
    }

    // ...nor for itself, via the other grant path.
    #[test]
    #[expected_failure(abort_code = 5, location = om2m_access::trust)]
    fun a8_revoked_cap_cannot_grant_admin_to_itself() {
        let mut sc = setup();
        arm_revoked_attacker(&mut sc);

        ts::next_tx(&mut sc, ATTACKER);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::grant_admin(&cap, &mut reg, ATTACKER, ts::ctx(&mut sc));
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        ts::end(sc);
    }

    // A8 core: a cap minted by the plain grant_admin path is in the validity
    // set (pre-A8 it was not, which made it permanently unrevocable).
    #[test]
    fun a8_grant_admin_registers_new_cap_in_validity_set() {
        let mut sc = setup();
        grant_plain(&mut sc, GRANTEE);
        let granted = cap_id_of(&mut sc, GRANTEE);

        ts::next_tx(&mut sc, ADMIN);
        {
            let reg = ts::take_shared<TrustRegistry>(&mut sc);
            assert!(trust::is_cap_valid(&reg, granted), 0);
            ts::return_shared(reg);
        };

        ts::end(sc);
    }

    // A8 core, the consequence: because grant_admin now registers the cap,
    // revoke_admin can actually take it away again.
    #[test]
    #[expected_failure(abort_code = 5, location = om2m_access::trust)]
    fun a8_cap_minted_by_grant_admin_is_revocable() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);

        grant_plain(&mut sc, GRANTEE);
        let granted = cap_id_of(&mut sc, GRANTEE);
        revoke(&mut sc, granted);

        ts::next_tx(&mut sc, GRANTEE);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::add_node(&cap, &mut reg, NODE2, 90, &clk); // -> 5
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Positive control for the whole delegation flow: a valid cap grants,
    // and the (non-revoked) grantee can write.
    #[test]
    fun a8_valid_cap_can_grant_and_grantee_can_write() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);

        grant_registered(&mut sc, GRANTEE);

        ts::next_tx(&mut sc, GRANTEE);
        {
            let cap = ts::take_from_sender<AdminCap>(&mut sc);
            let mut reg = ts::take_shared<TrustRegistry>(&mut sc);
            trust::add_node(&cap, &mut reg, NODE, 40, &clk);
            assert!(trust::score_of(&reg, NODE, &clk) == 40, 0);
            ts::return_shared(reg);
            ts::return_to_sender(&mut sc, cap);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }
}
