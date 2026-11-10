package org.eclipse.om2m.sui.trust;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.List;
import java.util.Properties;

import org.junit.Test;

/**
 * B3 (robust aggregation + Byzantine agreement bound), B9 (tier hysteresis) and
 * B11/B12 (8-signal weight scheme) invariants.
 */
public class TrustAggregationTest {

    private static NodeObservation sample(double v, boolean garbage) {
        return new NodeObservation("0xobs", "0xtgt", 1L, 1L,
                v, v, v, v, v, v, v, garbage);
    }

    private static TrustConfig defaults() {
        return TrustConfig.from(new Properties());
    }

    // ===================================================================
    // B3: median instead of arithmetic mean.
    // ===================================================================

    @Test
    public void medianIgnoresOneByzantineExtreme() {
        // Three observers; one reports a fabricated 0.0. The old mean gave
        // 0.5667 (enough to drag a target across a tier boundary on its own);
        // the median is the honest middle sample.
        List<NodeObservation> obs = Arrays.asList(
                sample(0.9, false), sample(0.0, false), sample(0.8, false));
        assertEquals("median must be the honest middle sample",
                0.8, TrustScoringEngine.median(obs, TrustScoringEngine.Signal.HEARTBEAT), 1e-9);
    }

    @Test
    public void medianOfEvenCountIsMeanOfTwoCentralSamples() {
        List<NodeObservation> obs = Arrays.asList(
                sample(1.0, false), sample(0.0, false),
                sample(0.8, false), sample(0.6, false));
        assertEquals(0.7, TrustScoringEngine.median(obs, TrustScoringEngine.Signal.RATE), 1e-9);
    }

    @Test
    public void medianOfSingleSampleIsThatSample() {
        List<NodeObservation> obs = Arrays.asList(sample(0.42, false));
        assertEquals(0.42, TrustScoringEngine.median(obs, TrustScoringEngine.Signal.CLOCK), 1e-9);
    }

    @Test
    public void medianReadsTheRequestedSignal() {
        NodeObservation o = new NodeObservation("0xo", "0xt", 1L, 1L,
                0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, false);
        List<NodeObservation> one = Arrays.asList(o);
        assertEquals(0.1, TrustScoringEngine.median(one, TrustScoringEngine.Signal.HEARTBEAT), 1e-9);
        assertEquals(0.2, TrustScoringEngine.median(one, TrustScoringEngine.Signal.MALFORMED), 1e-9);
        assertEquals(0.3, TrustScoringEngine.median(one, TrustScoringEngine.Signal.RATE), 1e-9);
        assertEquals(0.4, TrustScoringEngine.median(one, TrustScoringEngine.Signal.CLOCK), 1e-9);
        assertEquals(0.5, TrustScoringEngine.median(one, TrustScoringEngine.Signal.DENIED), 1e-9);
        assertEquals(0.6, TrustScoringEngine.median(one, TrustScoringEngine.Signal.HISTORICAL), 1e-9);
        assertEquals(0.7, TrustScoringEngine.median(one, TrustScoringEngine.Signal.INACTIVE), 1e-9);
    }

    // ===================================================================
    // B3: agreement threshold derived from the observer count.
    // ===================================================================

    @Test
    public void agreementThresholdIsStrictMajorityOfObservers() {
        // k = floor(n/2) + 1, replacing the fixed peerAgreementThreshold=2.
        // (floor((n-1)/2) + 1 gave exactly half for even n: 1,1,2,2,3,...)
        int[] expected = { 1, 2, 2, 3, 3, 4, 4, 5, 5 }; // n = 1..9
        for (int n = 1; n <= 9; n++) {
            assertEquals("k for n=" + n, expected[n - 1], TrustScoringEngine.agreementThreshold(n));
        }
    }

    @Test
    public void agreementThresholdIsMoreThanHalfForEveryN() {
        for (int n = 1; n <= 25; n++) {
            assertTrue("2k must exceed n at n=" + n, 2 * TrustScoringEngine.agreementThreshold(n) > n);
        }
    }

    @Test
    public void fiveNodeClusterTwoColludingObserversCannotZeroGarbage() {
        // 5 nodes -> 4 observers per target. Two Byzantine observers flag an
        // honest target; with the old k = floor((n-1)/2)+1 = 2 that zeroed it.
        List<NodeObservation> obs = Arrays.asList(
                sample(1.0, true), sample(1.0, true),
                sample(1.0, false), sample(1.0, false));
        assertEquals(1.0, TrustScoringEngine.garbageHealth(obs), 1e-9);
    }

    @Test
    public void fiveNodeClusterMajorityOfObserversDoesZeroGarbage() {
        List<NodeObservation> obs = Arrays.asList(
                sample(1.0, true), sample(1.0, true),
                sample(1.0, true), sample(1.0, false));
        assertEquals(0.0, TrustScoringEngine.garbageHealth(obs), 1e-9);
    }

    @Test
    public void fiveNodeClusterMedianIgnoresOneByzantineOfFour() {
        // Median of 4 has breakdown point 1: one extreme report stays bounded
        // by the honest samples.
        List<NodeObservation> obs = Arrays.asList(
                sample(0.0, false), sample(0.9, false),
                sample(0.9, false), sample(0.9, false));
        assertEquals(0.9, TrustScoringEngine.median(obs, TrustScoringEngine.Signal.HEARTBEAT), 1e-9);
    }

    @Test
    public void agreementThresholdToleratesFloorNMinus1Over2Faults() {
        for (int n = 1; n <= 25; n++) {
            int k = TrustScoringEngine.agreementThreshold(n);
            int tolerated = (n - 1) / 2;
            assertTrue("k must exceed the tolerated fault count at n=" + n, k > tolerated);
            assertTrue("k must not exceed n at n=" + n, k <= n);
        }
    }

    // ===================================================================
    // B11/B12: the 8-signal, 100-point weight scheme.
    // ===================================================================

    @Test
    public void weightsMatchTheEightSignalScheme() {
        TrustConfig cfg = defaults();
        assertEquals(25.0, cfg.wHeartbeat, 1e-9);
        assertEquals(25.0, cfg.wDeniedBurst, 1e-9);
        assertEquals(10.0, cfg.wMalformed, 1e-9);
        assertEquals(10.0, cfg.wRate, 1e-9);
        assertEquals(10.0, cfg.wHistorical, 1e-9);
        assertEquals(10.0, cfg.wGarbage, 1e-9);
        assertEquals(5.0, cfg.wClock, 1e-9);
        assertEquals(5.0, cfg.wInactive, 1e-9);
        assertEquals("the eight weights must sum to 100", 100.0, cfg.weightSum(), 1e-9);
    }

    @Test
    public void weightOverridesAreStillValidated() {
        Properties p = new Properties();
        p.setProperty("trust.weight.heartbeat", "30"); // 105 total
        try {
            TrustConfig.from(p);
            assertTrue("weights that do not sum to 100 must be rejected", false);
        } catch (IllegalStateException expected) {
            assertTrue(expected.getMessage().contains("sum to 100"));
        }
    }

    // ===================================================================
    // B9: tier hysteresis dead-band.
    // ===================================================================

    @Test
    public void crossingUpwardsNeedsToClearTheBoundaryByTheMargin() {
        TrustConfig cfg = defaults(); // boundaries 0,25,50,75,90; hysteresis 2.0
        assertFalse("76.0 is inside the dead-band above 75",
                cfg.clearsTierBoundary(76.0, 2, 3));
        assertTrue("77.0 clears 75 + 2",
                cfg.clearsTierBoundary(77.0, 2, 3));
    }

    @Test
    public void crossingDownwardsNeedsToClearTheBoundaryByTheMargin() {
        TrustConfig cfg = defaults();
        assertFalse("49.0 is inside the dead-band below 50",
                cfg.clearsTierBoundary(49.0, 2, 1));
        assertTrue("48.0 clears 50 - 2",
                cfg.clearsTierBoundary(48.0, 2, 1));
    }

    @Test
    public void sameTierIsNeverACrossing() {
        assertFalse(defaults().clearsTierBoundary(60.0, 2, 2));
    }

    @Test
    public void flappingOnABoundaryNeverCrosses() {
        // The production failure: an EMA oscillating by fractions of a point
        // around 75 produced four tier changes, i.e. four on-chain writes.
        TrustConfig cfg = defaults();
        double[] flap = { 75.1, 74.9, 75.2, 74.8, 75.05, 74.95 };
        for (double score : flap) {
            int from = 2, to = cfg.tierOf(score);
            if (to == from) continue;
            assertFalse("score " + score + " must not be allowed to cross",
                    cfg.clearsTierBoundary(score, from, to));
        }
    }

    @Test
    public void zeroHysteresisRestoresTheBareBoundaryTest() {
        Properties p = new Properties();
        p.setProperty("trust.tier.hysteresis", "0");
        TrustConfig cfg = TrustConfig.from(p);
        assertTrue("with the dead-band disabled, 75.0 crosses",
                cfg.clearsTierBoundary(75.0, 2, 3));
    }

    // ===================================================================
    // B9: a crossing must persist for more than one tick.
    // ===================================================================

    @Test
    public void candidateTierMustHoldForConsecutiveTicks() {
        TrustState st = new TrustState();
        assertEquals(1, st.observeCandidateTier(3));
        assertEquals(2, st.observeCandidateTier(3));
        assertEquals(3, st.observeCandidateTier(3));
        assertEquals("a different candidate restarts the count",
                1, st.observeCandidateTier(1));
        st.clearPendingTier();
        assertEquals(-1, st.pendingTier);
        assertEquals(0, st.pendingTicks);
        assertEquals("default confirm window", 2, defaults().tierConfirmTicks);
    }
}
