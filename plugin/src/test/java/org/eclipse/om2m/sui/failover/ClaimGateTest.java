package org.eclipse.om2m.sui.failover;

import static org.junit.Assert.assertEquals;

import org.eclipse.om2m.sui.failover.FailoverManager.ClaimGate;
import org.junit.Test;

/**
 * When a follower may submit failover::claim_parent.
 *
 * Every claim that claim_parent rejects is a PAID failed transaction. Before
 * this gate, the watchdog submitted a claim on every 5 s tick once the parent
 * went silent, so a 20 min lease cost about 240 aborted claims per follower per
 * failover. The gate submits only when the claim can succeed.
 */
public class ClaimGateTest {

    private static final String SELF = "0xaa";
    private static final String PARENT = "0xbb";
    private static final long NOW = 1_794_262_000_000L;
    private static final long GATE = 50;

    private static ClaimGate g(long leaseExpires, long score, String parent, long backoffUntil, boolean inFlight) {
        return FailoverManager.gateClaim(NOW, leaseExpires, score, GATE, parent, SELF, backoffUntil, inFlight);
    }

    @Test
    public void claimsWhenLeaseExpiredAndTrustClearsGate() {
        assertEquals(ClaimGate.CLAIM, g(NOW - 60_000, 80, PARENT, 0, false));
    }

    @Test
    public void waitsWhileTheLeaseIsStillValid() {
        // The case that used to cost ~240 paid aborts: parent silent, lease running.
        assertEquals(ClaimGate.LEASE_VALID, g(NOW + 600_000, 80, PARENT, 0, false));
    }

    @Test
    public void waitsOutTheSkewMarginJustAfterExpiry() {
        assertEquals(ClaimGate.LEASE_VALID, g(NOW - FailoverManager.LEASE_MARGIN_MS + 1, 80, PARENT, 0, false));
        assertEquals(ClaimGate.CLAIM,       g(NOW - FailoverManager.LEASE_MARGIN_MS,     80, PARENT, 0, false));
    }

    @Test
    public void doesNotClaimBelowTheTrustGate() {
        assertEquals(ClaimGate.TRUST_BELOW_GATE, g(NOW - 60_000, 49, PARENT, 0, false));
        assertEquals(ClaimGate.CLAIM,            g(NOW - 60_000, 50, PARENT, 0, false));
    }

    @Test
    public void doesNotClaimWhenTrustCouldNotBeRead() {
        assertEquals(ClaimGate.TRUST_UNKNOWN, g(NOW - 60_000, -1, PARENT, 0, false));
    }

    @Test
    public void neverClaimsAgainstItself() {
        assertEquals(ClaimGate.ALREADY_PARENT, g(NOW - 60_000, 80, SELF, 0, false));
    }

    @Test
    public void onlyOneClaimInFlightAndBackoffIsRespected() {
        assertEquals(ClaimGate.IN_FLIGHT, g(NOW - 60_000, 80, PARENT, 0, true));
        assertEquals(ClaimGate.BACKOFF,   g(NOW - 60_000, 80, PARENT, NOW + 1, false));
    }

    @Test
    public void backoffDoublesFrom15sAndCapsAt5min() {
        assertEquals(15_000L,  FailoverManager.claimBackoffMs(1));
        assertEquals(30_000L,  FailoverManager.claimBackoffMs(2));
        assertEquals(60_000L,  FailoverManager.claimBackoffMs(3));
        assertEquals(300_000L, FailoverManager.claimBackoffMs(10));
        assertEquals(300_000L, FailoverManager.claimBackoffMs(1000));
    }
}
