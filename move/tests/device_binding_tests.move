// device_binding_tests.move
//
// v10: a protected resource bound to an IoT device's on-chain identity.
//
//   DB1  bound + device registered as end device        -> GRANT (positive control)
//   DB2  device deregistered (council revoke)            -> E_DEVICE_NOT_REGISTERED (7)
//   DB3  re-registered after revoke                      -> GRANT again
//   DB4  bound address is a middleware node, not a device -> E_DEVICE_NOT_END_DEVICE (8)
//   DB5  reader list set, requester not on it            -> E_READER_NOT_ALLOWED (9)
//   DB6  reader list set, requester on it                -> GRANT
//   DB7  plain `evaluate` on a bound resource            -> E_DEVICE_BOUND (6)
//   DB8  the policy moves into the binding: the table no longer holds it
//        (which is what fences the old v8/v9 `evaluate` bytecode), and
//        unbind moves it back
//   DB9  op outside the binding's policy mask            -> E_OP_DENIED (2)
//   DB10 set_policy / add_blackout on a bound resource update the binding
//   DB11 evaluate_with_device on an unbound resource behaves like evaluate
//   DB12 bind requires an existing policy                -> E_POLICY_MISSING (1)
//   DB13 remove_policy on a bound resource removes the binding -> no access
//   DB14 reader add/remove bookkeeping (duplicate add, missing remove abort)

#[test_only]
module om2m_access::device_binding_tests {
    use std::string::{Self, String};
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};

    use om2m_access::identity::{Self, Registry as IdRegistry, AdminCap as IdAdminCap};
    use om2m_access::trust::{Self, TrustRegistry, AdminCap as TrustAdminCap};
    use om2m_access::cap_token::{Self, CapToken, IssuerCap};
    use om2m_access::policy::{Self, PolicyRegistry, PolicyAdminCap};

    const ADMIN:  address = @0xA11CE;
    const NODE:   address = @0xB0B;
    const OTHER:  address = @0xC0FFEE;
    const DEVICE: address = @0xD3;

    const OP_READ:   u8 = 1;
    const OP_DELETE: u8 = 4;
    const ALL_OPS:   u8 = 15;
    const MIN_TRUST: u64 = 50;

    const RES: vector<u8> = b"/in-cse/Cesp32-dht-01";
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

    fun register(sc: &mut Scenario, who: address, role: u8) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<IdAdminCap>(sc);
        let mut reg = ts::take_shared<IdRegistry>(sc);
        identity::register(&cap, &mut reg, who, string::utf8(b"x"), role, 0);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    fun deregister(sc: &mut Scenario, who: address) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<IdAdminCap>(sc);
        let mut reg = ts::take_shared<IdRegistry>(sc);
        identity::deregister(&cap, &mut reg, who);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    // NODE registered as MN-CSE, trust 90, READ|..|ADMIN token on RES,
    // policy (min 50, mask READ only) on RES.
    fun world(sc: &mut Scenario, clk: &Clock) {
        register(sc, NODE, identity::role_mn_cse());
        ts::next_tx(sc, ADMIN);
        {
            let cap = ts::take_from_sender<TrustAdminCap>(sc);
            let mut reg = ts::take_shared<TrustRegistry>(sc);
            trust::add_node(&cap, &mut reg, NODE, 90, clk);
            ts::return_shared(reg);
            ts::return_to_sender(sc, cap);
        };
        ts::next_tx(sc, ADMIN);
        {
            let issuer = ts::take_from_sender<IssuerCap>(sc);
            cap_token::mint(&issuer, NODE, string::utf8(RES), ALL_OPS, FAR_FUTURE, 100, ts::ctx(sc));
            ts::return_to_sender(sc, issuer);
        };
        ts::next_tx(sc, ADMIN);
        {
            let cap = ts::take_from_sender<PolicyAdminCap>(sc);
            let mut reg = ts::take_shared<PolicyRegistry>(sc);
            policy::set_policy(&cap, &mut reg, string::utf8(RES), MIN_TRUST, OP_READ);
            ts::return_shared(reg);
            ts::return_to_sender(sc, cap);
        };
    }

    fun bind(sc: &mut Scenario, device: address) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<PolicyAdminCap>(sc);
        let mut reg = ts::take_shared<PolicyRegistry>(sc);
        policy::bind_device(&cap, &mut reg, string::utf8(RES), device);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    fun add_reader(sc: &mut Scenario, reader: address) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<PolicyAdminCap>(sc);
        let mut reg = ts::take_shared<PolicyRegistry>(sc);
        policy::add_reader(&cap, &mut reg, string::utf8(RES), reader);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    fun remove_reader(sc: &mut Scenario, reader: address) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<PolicyAdminCap>(sc);
        let mut reg = ts::take_shared<PolicyRegistry>(sc);
        policy::remove_reader(&cap, &mut reg, string::utf8(RES), reader);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    // Steps 1-3 then step 4 via evaluate_with_device (or plain evaluate), as NODE.
    fun decide(sc: &mut Scenario, clk: &Clock, op: u8, with_device: bool): (address, String, u64) {
        ts::next_tx(sc, NODE);
        let id_reg = ts::take_shared<IdRegistry>(sc);
        let t_reg = ts::take_shared<TrustRegistry>(sc);
        let p_reg = ts::take_shared<PolicyRegistry>(sc);
        let mut tok = ts::take_from_sender<CapToken>(sc);

        let r1 = identity::verify(&id_reg, ts::ctx(sc));
        let r2 = trust::require_min(r1, &t_reg, string::utf8(RES), 0, clk);
        let r3 = cap_token::validate_for_use(r2, &mut tok, op, clk, ts::ctx(sc));
        let r4 = if (with_device) {
            policy::evaluate_with_device(r3, &p_reg, &t_reg, &id_reg, clk)
        } else {
            policy::evaluate(r3, &p_reg, &t_reg, clk)
        };
        let (req, res, _op, _score, min_trust, _uses) = policy::consume_policy_receipt(r4);

        ts::return_to_sender(sc, tok);
        ts::return_shared(p_reg);
        ts::return_shared(t_reg);
        ts::return_shared(id_reg);
        (req, res, min_trust)
    }

    fun start(): (Scenario, Clock) {
        let mut sc = setup();
        let clk = clock::create_for_testing(ts::ctx(&mut sc));
        world(&mut sc, &clk);
        (sc, clk)
    }

    fun finish(sc: Scenario, clk: Clock) {
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ---- tests ---------------------------------------------------------

    #[test]
    fun db1_bound_registered_device_grants() {
        let (mut sc, clk) = start();
        register(&mut sc, DEVICE, identity::role_ae());
        bind(&mut sc, DEVICE);
        let (req, res, min) = decide(&mut sc, &clk, OP_READ, true);
        assert!(req == NODE && res == string::utf8(RES) && min == MIN_TRUST, 0);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = om2m_access::policy)]
    fun db2_revoked_device_denies() {
        let (mut sc, clk) = start();
        register(&mut sc, DEVICE, identity::role_ae());
        bind(&mut sc, DEVICE);
        deregister(&mut sc, DEVICE);
        let (_a, _b, _c) = decide(&mut sc, &clk, OP_READ, true);
        finish(sc, clk);
    }

    #[test]
    fun db3_reregistered_device_grants_again() {
        let (mut sc, clk) = start();
        register(&mut sc, DEVICE, identity::role_ae());
        bind(&mut sc, DEVICE);
        deregister(&mut sc, DEVICE);
        register(&mut sc, DEVICE, identity::role_ae());
        let (req, _b, _c) = decide(&mut sc, &clk, OP_READ, true);
        assert!(req == NODE, 0);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = om2m_access::policy)]
    fun db4_bound_to_middleware_node_denies() {
        let (mut sc, clk) = start();
        bind(&mut sc, NODE); // NODE is registered, but as an MN-CSE
        let (_a, _b, _c) = decide(&mut sc, &clk, OP_READ, true);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 9, location = om2m_access::policy)]
    fun db5_reader_not_on_list_denies() {
        let (mut sc, clk) = start();
        register(&mut sc, DEVICE, identity::role_ae());
        bind(&mut sc, DEVICE);
        add_reader(&mut sc, OTHER);
        let (_a, _b, _c) = decide(&mut sc, &clk, OP_READ, true);
        finish(sc, clk);
    }

    #[test]
    fun db6_reader_on_list_grants() {
        let (mut sc, clk) = start();
        register(&mut sc, DEVICE, identity::role_ae());
        bind(&mut sc, DEVICE);
        add_reader(&mut sc, OTHER);
        add_reader(&mut sc, NODE);
        let (req, _b, _c) = decide(&mut sc, &clk, OP_READ, true);
        assert!(req == NODE, 0);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = om2m_access::policy)]
    fun db7_plain_evaluate_refused_on_bound_resource() {
        let (mut sc, clk) = start();
        register(&mut sc, DEVICE, identity::role_ae());
        bind(&mut sc, DEVICE);
        let (_a, _b, _c) = decide(&mut sc, &clk, OP_READ, false);
        finish(sc, clk);
    }

    #[test]
    fun db8_policy_moves_into_binding_and_back() {
        let (mut sc, clk) = start();
        register(&mut sc, DEVICE, identity::role_ae());
        bind(&mut sc, DEVICE);
        ts::next_tx(&mut sc, ADMIN);
        {
            let reg = ts::take_shared<PolicyRegistry>(&sc);
            let r = string::utf8(RES);
            assert!(policy::is_device_bound(&reg, &r), 0);
            assert!(policy::bound_device(&reg, &r) == DEVICE, 1);
            assert!(policy::has_policy(&reg, &r), 2);
            assert!(policy::min_trust_for(&reg, &r) == MIN_TRUST, 3);
            assert!(!policy::table_has_policy_for_testing(&reg, &r), 4); // fence for old bytecode
            ts::return_shared(reg);
        };
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<PolicyAdminCap>(&sc);
            let mut reg = ts::take_shared<PolicyRegistry>(&sc);
            policy::unbind_device(&cap, &mut reg, string::utf8(RES));
            let r = string::utf8(RES);
            assert!(!policy::is_device_bound(&reg, &r), 5);
            assert!(policy::table_has_policy_for_testing(&reg, &r), 6);
            ts::return_shared(reg);
            ts::return_to_sender(&sc, cap);
        };
        // unbound again: plain evaluate grants
        let (req, _b, _c) = decide(&mut sc, &clk, OP_READ, false);
        assert!(req == NODE, 7);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = om2m_access::policy)]
    fun db9_delete_outside_mask_denies() {
        let (mut sc, clk) = start();
        register(&mut sc, DEVICE, identity::role_ae());
        bind(&mut sc, DEVICE);
        let (_a, _b, _c) = decide(&mut sc, &clk, OP_DELETE, true);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::policy)]
    fun db10_policy_writes_reach_the_binding() {
        let (mut sc, mut clk) = start();
        register(&mut sc, DEVICE, identity::role_ae());
        bind(&mut sc, DEVICE);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<PolicyAdminCap>(&sc);
            let mut reg = ts::take_shared<PolicyRegistry>(&sc);
            policy::set_policy(&cap, &mut reg, string::utf8(RES), 60, OP_READ | OP_DELETE);
            let r = string::utf8(RES);
            assert!(policy::min_trust_for(&reg, &r) == 60, 0);
            assert!(policy::is_device_bound(&reg, &r), 1);
            assert!(!policy::table_has_policy_for_testing(&reg, &r), 2);
            policy::add_blackout(&cap, &mut reg, string::utf8(RES), 0, 10_000);
            ts::return_shared(reg);
            ts::return_to_sender(&sc, cap);
        };
        clock::set_for_testing(&mut clk, 5_000);
        let (_a, _b, _c) = decide(&mut sc, &clk, OP_DELETE, true); // mask now allows it; blackout fires
        finish(sc, clk);
    }

    #[test]
    fun db11_unbound_resource_behaves_like_evaluate() {
        let (mut sc, clk) = start();
        let (req, _b, min) = decide(&mut sc, &clk, OP_READ, true);
        assert!(req == NODE && min == MIN_TRUST, 0);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = om2m_access::policy)]
    fun db12_bind_requires_policy() {
        let mut sc = setup();
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<PolicyAdminCap>(&sc);
            let mut reg = ts::take_shared<PolicyRegistry>(&sc);
            policy::bind_device(&cap, &mut reg, string::utf8(RES), DEVICE);
            ts::return_shared(reg);
            ts::return_to_sender(&sc, cap);
        };
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = om2m_access::policy)]
    fun db13_remove_policy_removes_binding() {
        let (mut sc, clk) = start();
        register(&mut sc, DEVICE, identity::role_ae());
        bind(&mut sc, DEVICE);
        ts::next_tx(&mut sc, ADMIN);
        {
            let cap = ts::take_from_sender<PolicyAdminCap>(&sc);
            let mut reg = ts::take_shared<PolicyRegistry>(&sc);
            policy::remove_policy(&cap, &mut reg, string::utf8(RES));
            let r = string::utf8(RES);
            assert!(!policy::is_device_bound(&reg, &r) && !policy::has_policy(&reg, &r), 0);
            ts::return_shared(reg);
            ts::return_to_sender(&sc, cap);
        };
        let (_a, _b, _c) = decide(&mut sc, &clk, OP_READ, true);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 11, location = om2m_access::policy)]
    fun db14a_duplicate_reader_aborts() {
        let (mut sc, clk) = start();
        bind(&mut sc, DEVICE);
        add_reader(&mut sc, NODE);
        add_reader(&mut sc, NODE);
        finish(sc, clk);
    }

    #[test]
    #[expected_failure(abort_code = 12, location = om2m_access::policy)]
    fun db14b_removing_absent_reader_aborts() {
        let (mut sc, clk) = start();
        bind(&mut sc, DEVICE);
        add_reader(&mut sc, NODE);
        remove_reader(&mut sc, NODE);
        let reg_check = {
            ts::next_tx(&mut sc, ADMIN);
            let reg = ts::take_shared<PolicyRegistry>(&sc);
            let n = vector::length(&policy::readers_of(&reg, &string::utf8(RES)));
            ts::return_shared(reg);
            n
        };
        assert!(reg_check == 0, 0);
        remove_reader(&mut sc, NODE);
        finish(sc, clk);
    }
}
