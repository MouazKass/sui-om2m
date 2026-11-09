package org.eclipse.om2m.sui.trust;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/**
 * SY5 invariant: out-of-order / replayed gossip observations are rejected.
 * The decision is the pure predicate TrustGossip.isReplay(prev, incoming),
 * extracted so this invariant is directly unit-testable without the MQTT /
 * signature machinery. Mirrors the live SY5 demo where a captured-and-signed
 * older observation was replayed and rejected.
 *
 * <p><b>B6.</b> The ordinal is now the lexicographic pair
 * {@code (epoch, producedAtMs)} rather than {@code producedAtMs} alone. The
 * timestamp-only rule had a liveness bug: an observer whose wall clock moved
 * backwards across a restart (NTP step, RTC-less Pi booting before network
 * time) produced observations that looked older than the stored one forever,
 * so all of its gossip was permanently rejected as "replay". A bumped epoch now
 * means "this observer restarted" and is always accepted; within one epoch the
 * original strict-monotonicity rule is preserved exactly.
 */
public class TrustGossipReplayTest {

    private static final long EPOCH_1 = 1L;
    private static final long EPOCH_2 = 2L;

    private static NodeObservation obs(String observer, String target,
                                       long epoch, long producedAtMs) {
        return new NodeObservation(
            observer, target, epoch, producedAtMs,
            0d, 0d, 0d, 0d,
            0d, 0d, 0d,
            false
        );
    }

    private static final String OBSERVER = "0xobserver";
    private static final String TARGET   = "0xtarget";

    // =================================================================
    // Same epoch: the original strictly-increasing-timestamp behaviour.
    // =================================================================

    @Test
    public void sameEpochNewerObservationIsNotReplay() {
        NodeObservation prev = obs(OBSERVER, TARGET, EPOCH_1, 1000L);
        NodeObservation incoming = obs(OBSERVER, TARGET, EPOCH_1, 2000L);
        assertFalse("within one epoch, a strictly newer observation must be accepted",
                TrustGossip.isReplay(prev, incoming));
    }

    @Test
    public void sameEpochOlderObservationIsReplay() {
        NodeObservation prev = obs(OBSERVER, TARGET, EPOCH_1, 2000L);
        NodeObservation incoming = obs(OBSERVER, TARGET, EPOCH_1, 1000L);
        assertTrue("within one epoch, an older observation must be rejected as a replay",
                TrustGossip.isReplay(prev, incoming));
    }

    @Test
    public void sameEpochEqualTimestampIsReplay() {
        NodeObservation prev = obs(OBSERVER, TARGET, EPOCH_1, 1500L);
        NodeObservation incoming = obs(OBSERVER, TARGET, EPOCH_1, 1500L);
        assertTrue("within one epoch, a duplicate (equal producedAtMs) must be rejected",
                TrustGossip.isReplay(prev, incoming));
    }

    @Test
    public void firstObservationForPairIsNotReplay() {
        NodeObservation incoming = obs(OBSERVER, TARGET, EPOCH_1, 1000L);
        assertFalse("with no prior observation, the first one is accepted",
                TrustGossip.isReplay(null, incoming));
    }

    // =================================================================
    // B6: a newer epoch is always accepted, timestamp notwithstanding.
    // =================================================================

    @Test
    public void newerEpochWithLowerTimestampIsNotReplay() {
        // The restart case this fix exists for: the observer rebooted and came
        // back with a clock that had moved backwards by an hour.
        NodeObservation prev = obs(OBSERVER, TARGET, EPOCH_1, 5_000_000L);
        NodeObservation incoming = obs(OBSERVER, TARGET, EPOCH_2, 1_400_000L);
        assertFalse("a higher epoch must be accepted even with a lower producedAtMs",
                TrustGossip.isReplay(prev, incoming));
    }

    @Test
    public void newerEpochWithEqualTimestampIsNotReplay() {
        NodeObservation prev = obs(OBSERVER, TARGET, EPOCH_1, 1500L);
        NodeObservation incoming = obs(OBSERVER, TARGET, EPOCH_2, 1500L);
        assertFalse("a higher epoch must be accepted even with an equal producedAtMs",
                TrustGossip.isReplay(prev, incoming));
    }

    @Test
    public void newerEpochWithHigherTimestampIsNotReplay() {
        NodeObservation prev = obs(OBSERVER, TARGET, EPOCH_1, 1000L);
        NodeObservation incoming = obs(OBSERVER, TARGET, EPOCH_2, 2000L);
        assertFalse("a higher epoch with a higher timestamp is plainly fresh",
                TrustGossip.isReplay(prev, incoming));
    }

    @Test
    public void olderEpochIsReplayEvenWithHigherTimestamp() {
        // An attacker replaying a pre-restart capture cannot get it accepted by
        // pairing it with a far-future timestamp: the epoch pins it as stale.
        NodeObservation prev = obs(OBSERVER, TARGET, EPOCH_2, 1000L);
        NodeObservation incoming = obs(OBSERVER, TARGET, EPOCH_1, 9_999_999L);
        assertTrue("a lower epoch must be rejected regardless of producedAtMs",
                TrustGossip.isReplay(prev, incoming));
    }

    // =================================================================
    // Wire format v2 round-trip (epoch must survive encode/decode).
    // =================================================================

    @Test
    public void epochSurvivesWireRoundTrip() {
        NodeObservation o = new NodeObservation(
            OBSERVER, TARGET, 42L, 1234L,
            1d, 0.5d, 0.25d, 0.125d,
            0.75d, 0.875d, 1d,
            true);
        String wire = o.encode();
        assertTrue("v2 marker expected, got: " + wire, wire.startsWith("v2|"));
        NodeObservation back = NodeObservation.decode(wire);
        assertTrue("decode must accept its own v2 encoding", back != null);
        assertTrue("epoch must round-trip", back.epoch == 42L);
        assertTrue("producedAtMs must round-trip", back.producedAtMs == 1234L);
        assertTrue("garbage flag must round-trip", back.garbageFlag);
        assertFalse("a decoded v2 observation must not be a replay of itself-minus-one",
                TrustGossip.isReplay(obs(OBSERVER, TARGET, 41L, 9999L), back));
    }

    @Test
    public void v1WireFormatIsRejected() {
        // Old 15-field signed / 15-field unsigned v1 payloads carried different
        // fields in different positions; accepting them would silently
        // mis-assign health values.
        String v1 = "v1|0xobserver|0xtarget|1000|1.000|1.000|1.000|1.000"
                  + "|1.000|1.000|1.000|1.000|0|0|0";
        assertTrue("v1 payloads must be rejected by the v2 decoder",
                NodeObservation.decode(v1) == null);
    }
}
