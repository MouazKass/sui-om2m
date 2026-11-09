package org.eclipse.om2m.sui.trust;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Properties;
import java.util.Set;

import org.junit.Test;

/**
 * The engine's on-chain write path against a hermetic model of
 * {@code move/sources/trust.move} (no network, no MQTT, no filesystem).
 *
 * <p>{@link FakeMoveChain} reproduces exactly the Move rules the engine has to
 * live with:
 * <ul>
 *   <li>{@code score_of} returns the DECAYED score: stored minus 1 per FULL day
 *       since {@code last_update_ms}, floored at 0;</li>
 *   <li>{@code increase}/{@code decrease} apply the delta to the decayed score
 *       (clamped to [0,100]) and set {@code last_update_ms = now}; a delta of 0
 *       is legal and only re-anchors the decay clock;</li>
 *   <li>A12: {@code delta > 15} aborts with E_DELTA_TOO_LARGE (6), a write less
 *       than 60 s after {@code last_update_ms} aborts with E_RATE_LIMITED (7);</li>
 *   <li>self-scoring aborts with E_SELF_SCORING (4).</li>
 * </ul>
 * Aborts are reported in the same {@code MoveAbort(...)} text SuiRpcClient
 * produces, so the engine's abort-code parsing is exercised for real.
 */
public class TrustEngineChainWriteTest {

    private static final String SELF   = "0xbbbb";
    private static final String LOWER  = "0xaaaa";   // would win the submitter election
    private static final String TARGET = "0xcccc";
    private static final String CAP    = "0xcap";

    private static final long SEC = 1_000L;
    private static final long MIN = 60 * SEC;
    private static final long HOUR = 60 * MIN;
    private static final long DAY = 24 * HOUR;
    private static final long T0 = 1_800_000_000_000L;   // arbitrary epoch ms

    // =================================================================
    // Hermetic model of trust.move.
    // =================================================================

    static final class Write {
        final long atMs; final long mag; final boolean increase; final int abortCode;
        Write(long atMs, long mag, boolean increase, int abortCode) {
            this.atMs = atMs; this.mag = mag; this.increase = increase; this.abortCode = abortCode;
        }
        boolean ok() { return abortCode == 0; }
    }

    static final class FakeMoveChain implements TrustScoringEngine.TrustChain {
        long maxDelta = 15;
        long minIntervalMs = 60_000;
        /** Chain clock = simulated local clock + skew. */
        long skewMs;
        long nowMs;
        long score;
        long lastUpdateMs;
        /** Non-zero: every submit aborts with this code (e.g. 5 = cap revoked). */
        int forcedAbort;
        /** Simulate another submitter writing just before our next N submits. */
        int foreignWritesPending;
        int reads;
        final List<Write> writes = new ArrayList<>();

        FakeMoveChain(long score, long lastUpdateMs) {
            this.score = score;
            this.lastUpdateMs = lastUpdateMs;
        }

        long chainNow() { return nowMs + skewMs; }

        long decayed(long now) {
            if (now <= lastUpdateMs) return score;
            long days = (now - lastUpdateMs) / DAY;
            return days >= score ? 0 : score - days;
        }

        long scoreOf() { return decayed(chainNow()); }

        @Override public long readTrustScore(String target) {
            reads++;
            return scoreOf();
        }

        @Override public TrustScoringEngine.WriteResult submitTrustDelta(
                String submitter, String target, long magnitude, boolean increase, String cap) {
            long now = chainNow();
            if (foreignWritesPending > 0) {
                foreignWritesPending--;
                score = decayed(now);          // another submitter's 0-delta write
                lastUpdateMs = now;
            }
            int code = 0;
            if (submitter.equalsIgnoreCase(target))           code = 4;
            else if (forcedAbort != 0)                        code = forcedAbort;
            else if (magnitude > maxDelta)                    code = 6;
            else if (now < lastUpdateMs + minIntervalMs)      code = 7;
            writes.add(new Write(nowMs, magnitude, increase, code));
            if (code != 0) {
                return new TrustScoringEngine.WriteResult(false, "digest", 5, abortText(code));
            }
            long old = decayed(now);
            long nu = increase ? Math.min(100, old + magnitude) : Math.max(0, old - magnitude);
            score = nu;
            lastUpdateMs = now;
            return new TrustScoringEngine.WriteResult(true, "digest", 5, null);
        }

        static String abortText(int code) {
            return "MoveAbort(MoveLocation { module: ModuleId { address: 0xpkg, name: Identifier(\"trust\") },"
                 + " function_name: Some(\"increase\"), instruction: 17 }, " + code
                 + ") -- Move abort in trust::increase";
        }

        int aborts() { int n = 0; for (Write w : writes) if (!w.ok()) n++; return n; }
        int aborts(int code) { int n = 0; for (Write w : writes) if (w.abortCode == code) n++; return n; }
        int increases() { int n = 0; for (Write w : writes) if (w.increase && w.mag > 0) n++; return n; }
    }

    /** Controllable cluster view: one observation of TARGET per tick. */
    static final class FakeView implements TrustScoringEngine.PeerView {
        final Set<String> alive = new HashSet<>();
        double heartbeat = 1.0;
        double health = 1.0;

        FakeView(String... aliveAddrs) { Collections.addAll(alive, aliveAddrs); }

        /** Signals giving aggregate score s with a healthy heartbeat: 25 + 65v + 10 = s. */
        void scoreWithHeartbeat(double s) { heartbeat = 1.0; health = (s - 35.0) / 65.0; }
        /** All signals equal: 90v + 10 = s. */
        void uniformScore(double s) { heartbeat = (s - 10.0) / 90.0; health = heartbeat; }

        @Override public List<NodeObservation> observationsOf(String target, long now) {
            List<NodeObservation> l = new ArrayList<>();
            l.add(new NodeObservation(SELF, target, 1L, now,
                    heartbeat, health, health, health, health, health, health, false));
            return l;
        }
        @Override public Set<String> aliveNodes(long now) { return alive; }
        @Override public boolean isAlive(String addr, long now) { return alive.contains(addr); }
    }

    private static TrustConfig cfg() { return TrustConfig.from(new Properties()); }

    private static TrustScoringEngine engine(TrustConfig c, FakeMoveChain ch, FakeView v) {
        return new TrustScoringEngine(c, ch, v, SELF, CAP);
    }

    /** Drive scoreTarget(TARGET) from {@code from} (inclusive) to {@code to} (exclusive). */
    private static long run(TrustScoringEngine e, FakeMoveChain ch, long from, long to, long step) {
        long t = from;
        for (; t < to; t += step) {
            ch.nowMs = t;
            e.scoreTarget(TARGET, t);
        }
        return t;
    }

    private static void assertPaced(FakeMoveChain ch, long minGap) {
        for (int i = 1; i < ch.writes.size(); i++) {
            long gap = ch.writes.get(i).atMs - ch.writes.get(i - 1).atMs;
            if (gap < minGap) {
                fail("write " + i + " submitted " + gap + " ms after the previous one (< " + minGap + ")");
            }
        }
    }

    // =================================================================
    // Defect 1: a stable node must not decay to death.
    // =================================================================

    @Test
    public void stableHealthyNodeHoldsItsScoreFor60Days() {
        FakeMoveChain ch = new FakeMoveChain(100, T0 - HOUR);
        FakeView v = new FakeView(SELF, TARGET);       // healthy: every signal 1.0 -> 100
        TrustScoringEngine e = engine(cfg(), ch, v);

        for (int day = 1; day <= 60; day++) {
            run(e, ch, T0 + (day - 1) * DAY, T0 + day * DAY, 10 * SEC);
            assertEquals("on-chain score after day " + day, 100, ch.scoreOf());
        }
        assertEquals("no write may abort", 0, ch.aborts());
        // ~2 zero-delta re-anchors per day, not one per tick.
        assertTrue("writes=" + ch.writes.size(), ch.writes.size() >= 120 && ch.writes.size() <= 125);
        for (Write w : ch.writes) assertEquals("re-attestation of a stable node is a 0-delta write", 0, w.mag);
        assertPaced(ch, 12 * HOUR);
    }

    @Test
    public void stableMidTierNodeHoldsItsScoreFor60Days() {
        // A node that is alive but imperfect (score 80, tier 75..89) is just as
        // exposed to decay as a perfect one.
        FakeMoveChain ch = new FakeMoveChain(80, T0 - HOUR);
        FakeView v = new FakeView(SELF, TARGET);
        v.scoreWithHeartbeat(80.0);
        TrustScoringEngine e = engine(cfg(), ch, v);

        run(e, ch, T0, T0 + 60 * DAY, 10 * SEC);
        assertEquals(80, ch.scoreOf());
        assertEquals(0, ch.aborts());
    }

    // =================================================================
    // Defect 2: writes are capped at MAX_DELTA and converge in steps.
    // =================================================================

    @Test
    public void dropFrom80To30ConvergesInCappedPacedStepsWithoutAborts() {
        TrustConfig c = cfg();
        FakeMoveChain ch = new FakeMoveChain(80, T0 - HOUR);
        FakeView v = new FakeView(SELF, TARGET);
        v.uniformScore(30.0);
        TrustScoringEngine e = engine(c, ch, v);

        run(e, ch, T0, T0 + 30 * MIN, SEC);              // 1 s ticks, as in production

        assertEquals("no write may abort (no paid failures)", 0, ch.aborts());
        assertEquals("on-chain tier must reach the observed tier", c.tierOf(30), c.tierOf(ch.scoreOf()));
        assertTrue("needs several capped steps, got " + ch.writes.size(), ch.writes.size() >= 3);
        for (Write w : ch.writes) {
            assertTrue("each write must be <= 15, was " + w.mag, w.mag <= 15);
            assertTrue("a drop is written as decreases", !w.increase || w.mag == 0);
        }
        assertPaced(ch, 60 * SEC);
        assertEquals("engine's view must be the value actually on-chain",
                     ch.scoreOf(), Math.round(e.stateOf(TARGET).lastOnChain));
        assertEquals("crossing must be closed once the tier matches", -1, e.stateOf(TARGET).pendingTier);

        // The remainder inside the tier is finished by the next re-attestation.
        run(e, ch, T0 + 30 * MIN, T0 + 13 * HOUR, 10 * SEC);
        assertEquals(30, ch.scoreOf());
        assertEquals(0, ch.aborts());
    }

    @Test
    public void riseFrom20To95ConvergesInCappedSteps() {
        TrustConfig c = cfg();
        FakeMoveChain ch = new FakeMoveChain(20, T0 - HOUR);
        FakeView v = new FakeView(SELF, TARGET);          // healthy -> EMA climbs to 100
        TrustScoringEngine e = engine(c, ch, v);

        run(e, ch, T0, T0 + 30 * MIN, SEC);

        assertEquals(0, ch.aborts());
        assertEquals(c.tierOf(100), c.tierOf(ch.scoreOf()));
        for (Write w : ch.writes) assertTrue(w.mag <= 15);
        assertPaced(ch, 60 * SEC);
    }

    // =================================================================
    // Defect 3: write pacing.
    // =================================================================

    @Test
    public void noWriteIsEverSubmittedInsideTheMinInterval() {
        FakeMoveChain ch = new FakeMoveChain(60, T0 - HOUR);
        FakeView v = new FakeView(SELF, TARGET);
        TrustScoringEngine e = engine(cfg(), ch, v);

        // Score swings between 100 and 10 every 3 minutes for 6 hours, so a
        // write is wanted almost all the time.
        for (long t = T0; t < T0 + 6 * HOUR; t += SEC) {
            if (((t - T0) / (3 * MIN)) % 2 == 0) v.uniformScore(100.0); else v.uniformScore(10.0);
            ch.nowMs = t;
            e.scoreTarget(TARGET, t);
        }
        assertTrue("scenario must actually write a lot, got " + ch.writes.size(), ch.writes.size() > 50);
        assertPaced(ch, cfg().minWriteIntervalMs);
        assertEquals(0, ch.aborts());
    }

    // =================================================================
    // TR4: a silent / offline target is NOT re-attested.
    // =================================================================

    @Test
    public void silentTargetIsNotReattestedAndIsAllowedToDecay() {
        TrustConfig c = cfg();
        FakeMoveChain ch = new FakeMoveChain(100, T0 - HOUR);
        // TARGET has stopped gossiping (not alive) and nobody hears its
        // heartbeat. Its request-derived signals stay at their 1.0 defaults,
        // so the EMA bottoms out at 75, not 0.
        FakeView v = new FakeView(SELF);
        v.heartbeat = 0.0;
        v.health = 1.0;
        TrustScoringEngine e = engine(c, ch, v);

        run(e, ch, T0, T0 + 60 * DAY, 10 * SEC);

        assertEquals("never written upward", 0, ch.increases());
        assertEquals(0, ch.aborts());
        // It was written DOWN out of the top tier (100 -> 85) and then left alone.
        assertEquals("one capped write-down, no re-attestation", 1, ch.writes.size());
        assertEquals(false, ch.writes.get(0).increase);
        // Written at T0+70s; the run ends at T0+60d-10s: 59 full days of decay.
        assertEquals("then decays 1/day", 85 - 59, ch.scoreOf());
    }

    @Test
    public void gossipAliveTargetWhoseHeartbeatNobodyHearsIsNotFresh() {
        FakeMoveChain ch = new FakeMoveChain(80, T0 - HOUR);
        FakeView v = new FakeView(SELF, TARGET);    // gossips...
        v.heartbeat = 0.0;                          // ...but no observer hears a beat
        v.health = 1.0;                             // EMA -> 75, same tier as 80
        TrustScoringEngine e = engine(cfg(), ch, v);

        run(e, ch, T0, T0 + 10 * DAY, 10 * SEC);
        assertEquals("not re-attested", 0, ch.writes.size());
        assertEquals(70, ch.scoreOf());
    }

    // =================================================================
    // Non-submitters never write (B5 / B5b preserved).
    // =================================================================

    @Test
    public void nonSubmitterNeverWritesButTracksTheChain() {
        FakeMoveChain ch = new FakeMoveChain(80, T0 - HOUR);
        FakeView v = new FakeView(LOWER, SELF, TARGET);   // LOWER is the submitter
        v.uniformScore(30.0);
        TrustScoringEngine e = engine(cfg(), ch, v);

        run(e, ch, T0, T0 + 10 * MIN, SEC);
        assertEquals("a non-submitter must never write", 0, ch.writes.size());
        assertTrue("B5b: the crossing stays pending and is checked on-chain", ch.reads > 1);
        assertTrue(e.stateOf(TARGET).pendingTier != -1);

        // The real submitter lands the crossing; B5b sees it and goes quiet.
        ch.score = 35; ch.lastUpdateMs = ch.chainNow();
        run(e, ch, T0 + 10 * MIN, T0 + 10 * MIN + 5 * SEC, SEC);
        assertEquals(-1, e.stateOf(TARGET).pendingTier);
        assertEquals(35.0, e.stateOf(TARGET).lastOnChain, 1e-9);

        // A healthy, stable target: still no writes from a non-submitter.
        v.alive.add(TARGET);
        v.uniformScore(100.0);
        run(e, ch, T0 + 11 * MIN, T0 + 5 * DAY, 10 * SEC);
        assertEquals(0, ch.writes.size());
    }

    // =================================================================
    // Abort 6 / 7 => back off, not a tight retry loop.
    // =================================================================

    @Test
    public void rateLimitedAbortBacksOffAndRetries() {
        TrustConfig c = cfg();
        FakeMoveChain ch = new FakeMoveChain(80, T0 - HOUR);
        ch.foreignWritesPending = 3;              // another submitter beats us 3 times
        FakeView v = new FakeView(SELF, TARGET);
        v.uniformScore(30.0);
        TrustScoringEngine e = engine(c, ch, v);

        run(e, ch, T0, T0 + 20 * MIN, SEC);

        assertEquals(3, ch.aborts(7));
        assertEquals("no other aborts", 3, ch.aborts());
        assertPaced(ch, c.minWriteIntervalMs);
        assertTrue("bounded attempts, got " + ch.writes.size(), ch.writes.size() <= 8);
        assertEquals("still converges after backing off", c.tierOf(30), c.tierOf(ch.scoreOf()));
    }

    @Test
    public void deltaTooLargeAbortBacksOffAndShrinksTheStep() {
        TrustConfig c = cfg();
        FakeMoveChain ch = new FakeMoveChain(80, T0 - HOUR);
        ch.maxDelta = 10;                         // chain stricter than trust.max.delta
        FakeView v = new FakeView(SELF, TARGET);
        v.uniformScore(30.0);
        TrustScoringEngine e = engine(c, ch, v);

        run(e, ch, T0, T0 + 30 * MIN, SEC);

        assertEquals("only the first oversized write aborts", 1, ch.aborts(6));
        assertEquals(1, ch.aborts());
        assertPaced(ch, c.minWriteIntervalMs);
        assertEquals(c.tierOf(30), c.tierOf(ch.scoreOf()));
    }

    @Test
    public void persistentFailureBacksOffExponentially() {
        FakeMoveChain ch = new FakeMoveChain(80, T0 - HOUR);
        ch.forcedAbort = 5;                       // E_CAP_REVOKED: never succeeds
        FakeView v = new FakeView(SELF, TARGET);
        v.uniformScore(30.0);
        TrustScoringEngine e = engine(cfg(), ch, v);

        run(e, ch, T0, T0 + 2 * HOUR, SEC);       // 7200 ticks

        assertTrue("attempts in 2 h: " + ch.writes.size(), ch.writes.size() <= 8);
        for (int i = 2; i < ch.writes.size(); i++) {
            long g1 = ch.writes.get(i - 1).atMs - ch.writes.get(i - 2).atMs;
            long g2 = ch.writes.get(i).atMs - ch.writes.get(i - 1).atMs;
            assertTrue("backoff must not shrink", g2 >= g1);
            assertTrue("backoff capped at 1 h", g2 <= TrustScoringEngine.MAX_FAILURE_BACKOFF_MS + SEC);
        }
    }

    @Test
    public void restartedEngineWaitsOneIntervalBeforeItsFirstWrite() {
        // The previous incarnation may have written seconds ago.
        FakeMoveChain ch = new FakeMoveChain(80, T0 - 5 * SEC);
        FakeView v = new FakeView(SELF, TARGET);
        v.uniformScore(30.0);
        TrustScoringEngine e = engine(cfg(), ch, v);
        run(e, ch, T0, T0 + 5 * MIN, SEC);
        assertEquals(0, ch.aborts());
        assertTrue(ch.writes.get(0).atMs - T0 >= cfg().minWriteIntervalMs);
    }

    // =================================================================
    // Small pieces.
    // =================================================================

    @Test
    public void abortCodeIsParsedFromTheSuiRpcClientFormat() {
        assertEquals(7, TrustScoringEngine.moveAbortCode(FakeMoveChain.abortText(7)));
        assertEquals(6, TrustScoringEngine.moveAbortCode(FakeMoveChain.abortText(6)));
        assertEquals(-1, TrustScoringEngine.moveAbortCode(null));
        assertEquals(-1, TrustScoringEngine.moveAbortCode("connection reset"));
        assertEquals("another module's abort 7 is not trust::E_RATE_LIMITED", -1,
            TrustScoringEngine.moveAbortCode(
                "MoveAbort(MoveLocation { module: ModuleId { address: 0x1, name: Identifier(\"policy\") },"
              + " function_name: Some(\"f\") }, 7) -- x"));
    }

    @Test
    public void newConfigKeysHaveMoveMatchingDefaults() {
        TrustConfig c = cfg();
        assertEquals(15L, c.maxDelta);
        assertEquals(65_000L, c.minWriteIntervalMs);
        assertEquals(43_200_000L, c.reattestPeriodMs);
    }

    @Test
    public void newConfigKeysAreValidated() {
        String[][] bad = {
            { "trust.max.delta", "0" },
            { "trust.min.write.interval.ms", "59999" },
            { "trust.reattest.period.ms", "0" },
            { "trust.reattest.period.ms", "86400000" },   // a decay point would accrue
        };
        for (String[] kv : bad) {
            Properties p = new Properties();
            p.setProperty(kv[0], kv[1]);
            try {
                TrustConfig.from(p);
                fail(kv[0] + "=" + kv[1] + " must be rejected");
            } catch (IllegalStateException expected) { /* ok */ }
        }
    }
}
