// failover_lease_tests.move
//
// Offline unit proofs for the v8 A10 fix in failover.move: `renew_lease` now
// asserts `new_lease_ms <= MAX_LEASE_MS` (3_600_000 ms = 1 hour).
//
// Why this is a security fix and not a tidy-up: `claim_parent` only lets a
// candidate take over once `now >= cluster.lease_expires_ms`. Before A10 the
// current parent could call `renew_lease(cluster, u64::MAX, ...)` once and push
// `lease_expires_ms` so far into the future that the takeover branch of
// slide 10's failover flow became permanently unreachable — a one-transaction,
// irreversible denial of service against the whole failover mechanism,
// available to any node that happened to be parent at the time (and to any
// attacker who compromised it). The bound caps the stall at one hour.
//
// Abort codes exercised here (verified against failover.move):
//   failover::E_TRUST_BELOW_GATE  = 2   (not used; listed for orientation)
//   failover::E_LEASE_STILL_VALID = 3
//   failover::E_NOT_PARENT_ROLE   = 4
//   failover::E_LEASE_TOO_LONG    = 7
//   failover::MAX_LEASE_MS        = 3_600_000
//
// ------------------------------------------------------------------------
// REQUIRED SOURCE ADDITION (NOT owned by this workstream)
// ------------------------------------------------------------------------
// The end-to-end takeover control (a10_takeover_remains_reachable_...) needs
// an identity::Registry, which is created only by identity's private `init`.
// identity.move therefore needs the one-line test-only initializer that
// trust.move, cap_token.move and policy.move already carry:
//
//   #[test_only] public fun init_for_testing(ctx: &mut sui::tx_context::TxContext) { init(ctx) }
//
// The four pure renew_lease tests do not depend on it.
//
// Run with:  sui move test

#[test_only]
module om2m_access::failover_lease_tests {
    use std::string;
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};

    use om2m_access::identity::{Self, Registry as IdRegistry, AdminCap as IdAdminCap};
    use om2m_access::trust::{Self, TrustRegistry, AdminCap as TrustAdminCap};
    use om2m_access::failover::{Self, Cluster};

    const ADMIN: address     = @0xA11CE; // creates the cluster
    const PARENT: address    = @0xBEEF;  // initial / current parent
    const CANDIDATE: address = @0xC0FFEE;// eligible MN-CSE that wants to take over
    const ATTACKER: address  = @0xBAD;   // neither parent nor candidate

    // Mirrors failover::MAX_LEASE_MS.
    const MAX_LEASE_MS: u64 = 3_600_000;
    // What the deployed proxy actually asks for per renewal
    // (failover.lease.anchor.period.ms = 600_000, renewed at 2x).
    const TYPICAL_LEASE_MS: u64 = 1_200_000;
    const U64_MAX: u64 = 18_446_744_073_709_551_615;

    const TRUST_GATE: u64 = 60;
    const INITIAL_LEASE_MS: u64 = 60_000;

    // ---- helpers -------------------------------------------------------

    fun setup(): Scenario {
        let mut sc = ts::begin(ADMIN);
        {
            let ctx = ts::ctx(&mut sc);
            identity::init_for_testing(ctx);
            trust::init_for_testing(ctx);
        };
        sc
    }

    fun mk_clock(sc: &mut Scenario): Clock {
        clock::create_for_testing(ts::ctx(sc))
    }

    // Create a shared Cluster whose current parent is PARENT.
    fun make_cluster(sc: &mut Scenario, clk: &Clock) {
        ts::next_tx(sc, ADMIN);
        failover::create_cluster(
            b"EE_5", PARENT, TRUST_GATE, INITIAL_LEASE_MS, clk, ts::ctx(sc),
        );
    }

    fun register(sc: &mut Scenario, who: address, cse_id: vector<u8>, role: u8) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<IdAdminCap>(sc);
        let mut reg = ts::take_shared<IdRegistry>(sc);
        identity::register(&cap, &mut reg, who, string::utf8(cse_id), role, 0);
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

    // ---- A10 negative: the bound is enforced ---------------------------

    // `lease_expires_ms` is written in two places, so the bound has to hold in
    // both. `create_cluster` was initially left unbounded while `renew_lease`
    // was fixed, which left the same takeover-blocking attack reachable at
    // creation time: open a cluster with a u64::MAX initial lease and
    // `claim_parent` can never succeed. Creation is permissionless, so this is
    // not gated by holding any capability.
    #[test]
    #[expected_failure(abort_code = 7, location = om2m_access::failover)]
    fun a10_create_cluster_rejects_one_ms_over_max() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        failover::create_cluster(
            b"EE_OVER", PARENT, TRUST_GATE, MAX_LEASE_MS + 1, &clk, ts::ctx(&mut sc),
        );

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = om2m_access::failover)]
    fun a10_create_cluster_rejects_u64_max_forever_lease() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);

        ts::next_tx(&mut sc, ADMIN);
        failover::create_cluster(
            b"EE_FOREVER", PARENT, TRUST_GATE, U64_MAX, &clk, ts::ctx(&mut sc),
        );

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Positive control: creation at exactly the bound is still allowed, so the
    // new assertion rejects only what is genuinely out of range.
    #[test]
    fun a10_create_cluster_accepts_exact_max() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        clock::set_for_testing(&mut clk, 5_000);

        ts::next_tx(&mut sc, ADMIN);
        failover::create_cluster(
            b"EE_EXACT", PARENT, TRUST_GATE, MAX_LEASE_MS, &clk, ts::ctx(&mut sc),
        );

        ts::next_tx(&mut sc, ADMIN);
        {
            let cluster = ts::take_shared<Cluster>(&mut sc);
            assert!(failover::lease_expires_ms(&cluster) == 5_000 + MAX_LEASE_MS, 0);
            ts::return_shared(cluster);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // One millisecond over the bound is rejected -> E_LEASE_TOO_LONG (7).
    #[test]
    #[expected_failure(abort_code = 7, location = om2m_access::failover)]
    fun a10_renew_lease_rejects_one_ms_over_max() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        make_cluster(&mut sc, &clk);

        ts::next_tx(&mut sc, PARENT);
        {
            let mut cluster = ts::take_shared<Cluster>(&mut sc);
            failover::renew_lease(
                &mut cluster, MAX_LEASE_MS + 1, &clk, ts::ctx(&mut sc),
            );
            ts::return_shared(cluster);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // The actual pre-A10 attack: renew for u64::MAX and the cluster can never
    // fail over again. Now -> E_LEASE_TOO_LONG (7), and note the abort is the
    // explicit bound check, not an arithmetic overflow on `now + new_lease_ms`
    // (the bound is asserted before the addition).
    #[test]
    #[expected_failure(abort_code = 7, location = om2m_access::failover)]
    fun a10_renew_lease_rejects_u64_max_forever_lease() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        make_cluster(&mut sc, &clk);
        clock::set_for_testing(&mut clk, 1_000);

        ts::next_tx(&mut sc, PARENT);
        {
            let mut cluster = ts::take_shared<Cluster>(&mut sc);
            failover::renew_lease(&mut cluster, U64_MAX, &clk, ts::ctx(&mut sc));
            ts::return_shared(cluster);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Renewal is still parent-only: a bystander cannot renew (or reset) the
    // lease -> E_NOT_PARENT_ROLE (4).
    #[test]
    #[expected_failure(abort_code = 4, location = om2m_access::failover)]
    fun a10_non_parent_cannot_renew_lease() {
        let mut sc = setup();
        let clk = mk_clock(&mut sc);
        make_cluster(&mut sc, &clk);

        ts::next_tx(&mut sc, ATTACKER);
        {
            let mut cluster = ts::take_shared<Cluster>(&mut sc);
            failover::renew_lease(
                &mut cluster, TYPICAL_LEASE_MS, &clk, ts::ctx(&mut sc),
            );
            ts::return_shared(cluster);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // ---- A10 positive controls: honest renewals are unaffected ----------

    // The deployed cadence (1_200_000 ms) and the bound itself (3_600_000 ms)
    // are both accepted, and lease_expires_ms lands exactly at
    // now + new_lease_ms.
    #[test]
    fun a10_renew_lease_accepts_typical_and_exact_max() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        make_cluster(&mut sc, &clk);

        clock::set_for_testing(&mut clk, 1_000);
        ts::next_tx(&mut sc, PARENT);
        {
            let mut cluster = ts::take_shared<Cluster>(&mut sc);
            failover::renew_lease(
                &mut cluster, TYPICAL_LEASE_MS, &clk, ts::ctx(&mut sc),
            );
            assert!(failover::lease_expires_ms(&cluster) == 1_000 + TYPICAL_LEASE_MS, 0);
            ts::return_shared(cluster);
        };

        clock::set_for_testing(&mut clk, 2_000);
        ts::next_tx(&mut sc, PARENT);
        {
            let mut cluster = ts::take_shared<Cluster>(&mut sc);
            // exactly at the bound: <= is inclusive
            failover::renew_lease(&mut cluster, MAX_LEASE_MS, &clk, ts::ctx(&mut sc));
            assert!(failover::lease_expires_ms(&cluster) == 2_000 + MAX_LEASE_MS, 1);
            ts::return_shared(cluster);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // The property A10 actually buys: even after the parent renews for the
    // maximum permitted lease, the takeover path is still reachable — the
    // stall is bounded by one hour instead of being permanent.
    //
    // Also doubles as a positive control for the trust gate: CANDIDATE is a
    // registered MN-CSE scoring 80 against a gate of 60.
    #[test]
    fun a10_takeover_remains_reachable_after_max_renewal() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        make_cluster(&mut sc, &clk);
        register(&mut sc, CANDIDATE, b"mn-cse-2", identity::role_mn_cse());
        seed_trust(&mut sc, &clk, CANDIDATE, 80);

        // Parent stalls for the longest lease it is allowed to ask for.
        ts::next_tx(&mut sc, PARENT);
        {
            let mut cluster = ts::take_shared<Cluster>(&mut sc);
            failover::renew_lease(&mut cluster, MAX_LEASE_MS, &clk, ts::ctx(&mut sc));
            assert!(failover::lease_expires_ms(&cluster) == MAX_LEASE_MS, 0);
            assert!(failover::current_parent(&cluster) == PARENT, 1);
            ts::return_shared(cluster);
        };

        // One millisecond before expiry the lease still holds.
        clock::set_for_testing(&mut clk, MAX_LEASE_MS - 1);
        ts::next_tx(&mut sc, CANDIDATE);
        {
            let cluster = ts::take_shared<Cluster>(&mut sc);
            assert!(failover::lease_expires_ms(&cluster) > MAX_LEASE_MS - 1, 2);
            ts::return_shared(cluster);
        };

        // At expiry the candidate takes over.
        clock::set_for_testing(&mut clk, MAX_LEASE_MS);
        ts::next_tx(&mut sc, CANDIDATE);
        {
            let mut cluster = ts::take_shared<Cluster>(&mut sc);
            let id_reg = ts::take_shared<IdRegistry>(&mut sc);
            let t_reg = ts::take_shared<TrustRegistry>(&mut sc);
            failover::claim_parent(
                &mut cluster, &id_reg, &t_reg, &clk, ts::ctx(&mut sc),
            );
            assert!(failover::current_parent(&cluster) == CANDIDATE, 3);
            assert!(failover::epoch(&cluster) == 1, 4);
            ts::return_shared(t_reg);
            ts::return_shared(id_reg);
            ts::return_shared(cluster);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Negative control for the same mechanism: before the lease expires the
    // takeover is refused -> E_LEASE_STILL_VALID (3). This is what an
    // unbounded renewal turned into a permanent condition.
    #[test]
    #[expected_failure(abort_code = 3, location = om2m_access::failover)]
    fun a10_takeover_refused_while_lease_valid() {
        let mut sc = setup();
        let mut clk = mk_clock(&mut sc);
        make_cluster(&mut sc, &clk);
        register(&mut sc, CANDIDATE, b"mn-cse-2", identity::role_mn_cse());
        seed_trust(&mut sc, &clk, CANDIDATE, 80);

        ts::next_tx(&mut sc, PARENT);
        {
            let mut cluster = ts::take_shared<Cluster>(&mut sc);
            failover::renew_lease(&mut cluster, MAX_LEASE_MS, &clk, ts::ctx(&mut sc));
            ts::return_shared(cluster);
        };

        clock::set_for_testing(&mut clk, MAX_LEASE_MS - 1);
        ts::next_tx(&mut sc, CANDIDATE);
        {
            let mut cluster = ts::take_shared<Cluster>(&mut sc);
            let id_reg = ts::take_shared<IdRegistry>(&mut sc);
            let t_reg = ts::take_shared<TrustRegistry>(&mut sc);
            failover::claim_parent(
                &mut cluster, &id_reg, &t_reg, &clk, ts::ctx(&mut sc),
            );
            ts::return_shared(t_reg);
            ts::return_shared(id_reg);
            ts::return_shared(cluster);
        };

        clock::destroy_for_testing(clk);
        ts::end(sc);
    }
}
