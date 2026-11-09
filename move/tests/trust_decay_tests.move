// trust_decay_tests.move
//
// TR4 (lazy decay) and TR8 (bounded write) must hold on the EFFECTIVE score,
// i.e. what `score_of` / `require_min` actually use for decisions.
//
// The bug these pin down: `increase`/`decrease` used to apply the delta to the
// STORED `score` field — the value as of `last_update_ms`, before decay — and
// then reset `last_update_ms`. So any write erased all accumulated decay, and a
// single small write could move the effective score far beyond MAX_DELTA:
//
//     add_node(80); 60 days pass (effective 20); increase(1)  ->  81   (+61)
//
// The fix folds decay in first (`old = decayed(entry, now)`), so the same
// sequence yields 21 (+1). Each test below fails on the old behaviour.
//
// Decay is 1 point per full day (DECAY_PER_DAY = 1, MS_PER_DAY = 86_400_000).
//
// Run with:  sui move test

#[test_only]
module om2m_access::trust_decay_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};

    use om2m_access::trust::{Self, TrustRegistry, AdminCap};

    const ADMIN: address = @0xA11CE;
    const NODE: address = @0xB0B;          // scored node (!= sender)
    const DAY: u64 = 86_400_000;

    fun setup(): (Scenario, Clock) {
        let mut sc = ts::begin(ADMIN);
        trust::init_for_testing(ts::ctx(&mut sc));
        let clk = clock::create_for_testing(ts::ctx(&mut sc));
        (sc, clk)
    }

    fun seed(sc: &mut Scenario, clk: &Clock, score: u64) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let mut reg = ts::take_shared<TrustRegistry>(sc);
        trust::add_node(&cap, &mut reg, NODE, score, clk);
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    fun score(sc: &mut Scenario, clk: &Clock): u64 {
        ts::next_tx(sc, ADMIN);
        let reg = ts::take_shared<TrustRegistry>(sc);
        let s = trust::score_of(&reg, NODE, clk);
        ts::return_shared(reg);
        s
    }

    fun write(sc: &mut Scenario, clk: &Clock, delta: u64, up: bool) {
        ts::next_tx(sc, ADMIN);
        let cap = ts::take_from_sender<AdminCap>(sc);
        let mut reg = ts::take_shared<TrustRegistry>(sc);
        if (up) {
            trust::increase_guarded(&cap, &mut reg, NODE, delta, clk, ts::ctx(sc));
        } else {
            trust::decrease_guarded(&cap, &mut reg, NODE, delta, clk, ts::ctx(sc));
        };
        ts::return_shared(reg);
        ts::return_to_sender(sc, cap);
    }

    // Sanity: decay itself behaves as specified before any write happens.
    #[test]
    fun tr4_decays_one_point_per_day() {
        let (mut sc, mut clk) = setup();
        seed(&mut sc, &clk, 80);
        clock::set_for_testing(&mut clk, 20 * DAY);
        assert!(score(&mut sc, &clk) == 60, 0);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // TR4: a write must not erase decay. Old behaviour: 80 + 1 = 81.
    #[test]
    fun tr4_increase_does_not_erase_decay() {
        let (mut sc, mut clk) = setup();
        seed(&mut sc, &clk, 80);
        clock::set_for_testing(&mut clk, 60 * DAY);
        assert!(score(&mut sc, &clk) == 20, 0);
        write(&mut sc, &clk, 1, true);
        assert!(score(&mut sc, &clk) == 21, 1);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // TR8: one write moves the EFFECTIVE score by exactly the requested delta,
    // which A12 caps at MAX_DELTA. Old behaviour: +61 from a delta of 1.
    #[test]
    fun tr8_effective_change_equals_delta_after_decay() {
        let (mut sc, mut clk) = setup();
        seed(&mut sc, &clk, 80);
        clock::set_for_testing(&mut clk, 60 * DAY);
        let before = score(&mut sc, &clk);
        write(&mut sc, &clk, 15, true);
        let after = score(&mut sc, &clk);
        assert!(after - before == 15, 0);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Decrease applies to the decayed score too. Old behaviour: 80 - 10 = 70.
    #[test]
    fun tr4_decrease_applies_to_decayed_score() {
        let (mut sc, mut clk) = setup();
        seed(&mut sc, &clk, 80);
        clock::set_for_testing(&mut clk, 20 * DAY);   // effective 60
        write(&mut sc, &clk, 10, false);
        assert!(score(&mut sc, &clk) == 50, 0);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // A write re-anchors decay at the new effective score: one more day costs
    // exactly one point from the post-write value.
    #[test]
    fun tr4_write_reanchors_decay_clock() {
        let (mut sc, mut clk) = setup();
        seed(&mut sc, &clk, 80);
        clock::set_for_testing(&mut clk, 20 * DAY);   // effective 60
        write(&mut sc, &clk, 5, true);                // 65, re-anchored
        assert!(score(&mut sc, &clk) == 65, 0);
        clock::set_for_testing(&mut clk, 21 * DAY);
        assert!(score(&mut sc, &clk) == 64, 1);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Re-attestation: a stable healthy node is kept at its score by a small
    // periodic top-up — the pattern the trust engine now uses — instead of
    // silently decaying below the failover gate.
    #[test]
    fun tr4_periodic_reattestation_holds_score() {
        let (mut sc, mut clk) = setup();
        seed(&mut sc, &clk, 80);
        let mut day = 1;
        while (day <= 40) {
            clock::set_for_testing(&mut clk, day * DAY);   // decays to 79
            write(&mut sc, &clk, 1, true);                 // re-attest to 80
            day = day + 1;
        };
        assert!(score(&mut sc, &clk) == 80, 0);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }

    // Decay never underflows, and a write on a fully decayed node starts from 0.
    #[test]
    fun tr4_full_decay_floors_at_zero_then_write_from_zero() {
        let (mut sc, mut clk) = setup();
        seed(&mut sc, &clk, 30);
        clock::set_for_testing(&mut clk, 100 * DAY);
        assert!(score(&mut sc, &clk) == 0, 0);
        write(&mut sc, &clk, 15, true);
        assert!(score(&mut sc, &clk) == 15, 1);
        clock::destroy_for_testing(clk);
        ts::end(sc);
    }
}
