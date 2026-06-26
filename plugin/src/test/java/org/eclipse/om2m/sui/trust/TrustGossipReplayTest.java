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
 */
public class TrustGossipReplayTest {

    private static NodeObservation obs(String observer, String target, long producedAtMs) {
        return new NodeObservation(
            observer, target, producedAtMs,
            0d, 0d, 0d, 0d,
            0d, 0d, 0d, 0d,
            false, false, false
        );
    }

    private static final String OBSERVER = "0xobserver";
    private static final String TARGET   = "0xtarget";

    @Test
    public void newerObservationIsNotReplay() {
        NodeObservation prev = obs(OBSERVER, TARGET, 1000L);
        NodeObservation incoming = obs(OBSERVER, TARGET, 2000L);
        assertFalse("a strictly newer observation must be accepted",
                TrustGossip.isReplay(prev, incoming));
    }

    @Test
    public void olderObservationIsReplay() {
        NodeObservation prev = obs(OBSERVER, TARGET, 2000L);
        NodeObservation incoming = obs(OBSERVER, TARGET, 1000L);
        assertTrue("an older observation must be rejected as a replay",
                TrustGossip.isReplay(prev, incoming));
    }

    @Test
    public void equalTimestampIsReplay() {
        NodeObservation prev = obs(OBSERVER, TARGET, 1500L);
        NodeObservation incoming = obs(OBSERVER, TARGET, 1500L);
        assertTrue("a duplicate (equal producedAtMs) observation must be rejected",
                TrustGossip.isReplay(prev, incoming));
    }

    @Test
    public void firstObservationForPairIsNotReplay() {
        NodeObservation incoming = obs(OBSERVER, TARGET, 1000L);
        assertFalse("with no prior observation, the first one is accepted",
                TrustGossip.isReplay(null, incoming));
    }
}
