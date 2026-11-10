package org.eclipse.om2m.sui.das;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.util.concurrent.atomic.AtomicLong;

import org.junit.Test;

/**
 * F3: repeated DENYs are served locally (no simulation, no tx), and an
 * originator spraying forbidden requests is throttled, without ever turning a
 * DENY into a GRANT or punishing other originators.
 */
public class DenyGuardTest {

    private final AtomicLong now = new AtomicLong(1_000_000L);

    private DenyGuard guard(int cacheMax, long ttl, int rateMax, long window) {
        return new DenyGuard(cacheMax, ttl, rateMax, window, new DenyLog(null, 1 << 20, 0), now::get);
    }

    private static final byte R = 1, D = 4;

    @Test
    public void aVerdictIsCachedAndRepeatsNeverReachTheChain() {
        DenyGuard g = guard(16, 10_000, 0, 60_000);
        String k = DenyGuard.key("Cs", "/res", D);
        assertNull(g.preDecision("Cs", k));
        g.recordDeny("Cs", "0xa", "/res", D, DenyGuard.Source.SIMULATED, "abort 4");
        assertEquals(DenyGuard.Source.CACHED, g.preDecision("Cs", k));
        now.addAndGet(9_999);
        assertEquals(DenyGuard.Source.CACHED, g.preDecision("Cs", k));
    }

    @Test
    public void theCacheExpiresSoAPolicyChangeTakesEffect() {
        DenyGuard g = guard(16, 10_000, 0, 60_000);
        String k = DenyGuard.key("Cs", "/res", D);
        g.recordDeny("Cs", "0xa", "/res", D, DenyGuard.Source.CHAIN, "abort");
        now.addAndGet(10_000);
        assertNull(g.preDecision("Cs", k));
    }

    @Test
    public void theCacheIsPerOriginatorResourceAndOp() {
        DenyGuard g = guard(16, 10_000, 0, 60_000);
        g.recordDeny("Cs", "0xa", "/res", D, DenyGuard.Source.SIMULATED, "abort");
        assertNull("same resource, other op", g.preDecision("Cs", DenyGuard.key("Cs", "/res", R)));
        assertNull("other resource", g.preDecision("Cs", DenyGuard.key("Cs", "/other", D)));
        assertNull("other originator", g.preDecision("Cx", DenyGuard.key("Cx", "/res", D)));
    }

    @Test
    public void errorsAreNeverCachedOrCharged() {
        // An outage must not outlive itself by a TTL, nor throttle anybody.
        DenyGuard g = guard(16, 10_000, 1, 60_000);
        String k = DenyGuard.key("Cs", "/res", R);
        g.recordDeny("Cs", "0xa", "/res", R, DenyGuard.Source.ERROR, "precheck unavailable");
        g.recordDeny("Cs", "0xa", "/res", R, DenyGuard.Source.UNMAPPED, "no mapping");
        g.recordDeny("Cs", "0xa", "/res", R, DenyGuard.Source.CACHED, "cached");
        assertNull(g.preDecision("Cs", k));
        assertEquals(0, g.cachedKeys());
    }

    @Test
    public void anOriginatorOverItsDenyBudgetIsThrottledForTheWindow() {
        DenyGuard g = guard(64, 0, 3, 60_000);           // cache off: isolate the throttle
        for (int i = 0; i < 3; i++) {
            String res = "/r" + i;
            assertNull(g.preDecision("Cs", DenyGuard.key("Cs", res, D)));
            g.recordDeny("Cs", "0xa", res, D, DenyGuard.Source.SIMULATED, "abort");
        }
        assertEquals(DenyGuard.Source.THROTTLED, g.preDecision("Cs", DenyGuard.key("Cs", "/fresh", R)));
        assertNull("other originators are unaffected", g.preDecision("Cok", DenyGuard.key("Cok", "/r0", R)));
        now.addAndGet(60_000);
        assertNull("budget resets with the window", g.preDecision("Cs", DenyGuard.key("Cs", "/fresh", R)));
    }

    @Test
    public void belowTheBudgetNothingIsThrottled() {
        DenyGuard g = guard(64, 0, 3, 60_000);
        g.recordDeny("Cs", "0xa", "/a", D, DenyGuard.Source.SIMULATED, "abort");
        g.recordDeny("Cs", "0xa", "/b", D, DenyGuard.Source.SIMULATED, "abort");
        assertNull(g.preDecision("Cs", DenyGuard.key("Cs", "/c", R)));
    }

    @Test
    public void deniesOlderThanTheWindowStartANewWindow() {
        DenyGuard g = guard(64, 0, 2, 60_000);
        g.recordDeny("Cs", "0xa", "/a", D, DenyGuard.Source.SIMULATED, "abort");
        now.addAndGet(60_000);
        g.recordDeny("Cs", "0xa", "/b", D, DenyGuard.Source.SIMULATED, "abort");
        assertNull("1 in the new window < 2", g.preDecision("Cs", DenyGuard.key("Cs", "/c", R)));
    }

    @Test
    public void memoryIsBoundedWhateverTheAttackerInvents() {
        DenyGuard g = guard(8, 10_000, 0, 60_000);
        for (int i = 0; i < 1000; i++) {
            g.recordDeny("C" + i, "0xa", "/r" + i, D, DenyGuard.Source.SIMULATED, "abort");
        }
        assertTrue(g.cachedKeys() <= 8);
        // Most recent entries survive (LRU).
        assertEquals(DenyGuard.Source.CACHED, g.preDecision("C999", DenyGuard.key("C999", "/r999", D)));
    }
}
