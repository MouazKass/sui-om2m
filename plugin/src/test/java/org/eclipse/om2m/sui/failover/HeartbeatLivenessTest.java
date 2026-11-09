package org.eclipse.om2m.sui.failover;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.Base64;

import org.eclipse.om2m.sui.trust.SignedBeacon;
import org.junit.Test;

/**
 * Which heartbeats keep the parent alive (FailoverManager.countsForLiveness).
 *
 * The failure this pins down was measured on the testbed on 2026-11-10: the
 * three-broker mesh re-forwarded every message forever (about 213k deliveries
 * per 8 s carrying only 110 distinct payloads). A beat that loops, or is
 * captured and replayed, must stop counting once it is older than the
 * heartbeat timeout, otherwise a dead parent looks alive and failover never
 * happens.
 */
public class HeartbeatLivenessTest {

    private static final long TIMEOUT = 15_000L;
    private static final long NOW = 1_794_262_000_000L;

    private static SignedBeacon node(int seed) {
        byte[] b = new byte[33];
        Arrays.fill(b, 1, 33, (byte) seed);
        return SignedBeacon.fromKeystoreEntry(Base64.getEncoder().encodeToString(b));
    }

    private static final SignedBeacon PARENT = node(1);
    private static final SignedBeacon OTHER  = node(2);

    private static SignedBeacon.Verified beat(SignedBeacon who, long ts) {
        return SignedBeacon.verify(who.beat(0L, ts));
    }

    @Test
    public void freshBeatFromTheParentCounts() {
        assertTrue(FailoverManager.countsForLiveness(beat(PARENT, NOW - 3_000), PARENT.address(), NOW, TIMEOUT));
    }

    @Test
    public void beatFromANonParentDoesNotCount() {
        assertFalse(FailoverManager.countsForLiveness(beat(OTHER, NOW), PARENT.address(), NOW, TIMEOUT));
    }

    @Test
    public void staleOrLoopedBeatFromTheParentDoesNotCount() {
        // A genuine parent beat, still circulating (or replayed) a minute later.
        assertFalse("a dead parent must not be kept alive by its old beats",
            FailoverManager.countsForLiveness(beat(PARENT, NOW - 60_000), PARENT.address(), NOW, TIMEOUT));
    }

    @Test
    public void beatFarInTheFutureDoesNotCount() {
        assertFalse(FailoverManager.countsForLiveness(beat(PARENT, NOW + 60_000), PARENT.address(), NOW, TIMEOUT));
    }

    @Test
    public void boundaryIsInclusive() {
        assertTrue(FailoverManager.countsForLiveness(beat(PARENT, NOW - TIMEOUT), PARENT.address(), NOW, TIMEOUT));
        assertFalse(FailoverManager.countsForLiveness(beat(PARENT, NOW - TIMEOUT - 1), PARENT.address(), NOW, TIMEOUT));
    }

    @Test
    public void nothingCountsWhenUnverifiedOrNoParentKnown() {
        assertFalse(FailoverManager.countsForLiveness(null, PARENT.address(), NOW, TIMEOUT));
        assertFalse(FailoverManager.countsForLiveness(beat(PARENT, NOW), null, NOW, TIMEOUT));
    }
}
