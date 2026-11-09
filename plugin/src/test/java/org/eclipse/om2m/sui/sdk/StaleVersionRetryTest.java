package org.eclipse.om2m.sui.sdk;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.concurrent.atomic.AtomicInteger;

import org.junit.Test;

/**
 * Rebuild-and-retry on stale object versions (GraphQL indexer lag).
 *
 * Observed live on 2026-11-10: a newly elected parent's first lease anchor,
 * sent right after its claim, was refused because the gas coin version read
 * from the indexer had just been consumed. The post-claim lease is short, so
 * an unretried failure here loses the parent role.
 */
public class StaleVersionRetryTest {

    private static final String STALE =
        "Sui GraphQL error: Invalid argument: Error checking transaction input objects: Transaction needs"
        + " to be rebuilt because object 0x4d36 version 0x40b29993 is unavailable for consumption,"
        + " current version: 0x40b2d9d7 [BAD_USER_INPUT]";
    private static final String ABORT =
        "MoveAbort(MoveLocation { module: ModuleId { address: 0x88, name: Identifier(\"failover\") },"
        + " function_name: Some(\"claim_parent\"), instruction: 22 }, 3)";

    private static NativePtbBuilder.Result ok()           { return new NativePtbBuilder.Result(true, "D", 1, null); }
    private static NativePtbBuilder.Result fail(String e) { return new NativePtbBuilder.Result(false, null, 1, e); }

    @Test
    public void classifiesTheLiveErrorAsStaleAndAbortsAsNot() {
        assertTrue(NativePtbBuilder.isStaleObjectVersion(STALE));
        assertFalse(NativePtbBuilder.isStaleObjectVersion(ABORT));
        assertFalse(NativePtbBuilder.isStaleObjectVersion(null));
    }

    @Test
    public void staleThenSuccessIsRebuiltAndSucceeds() {
        AtomicInteger calls = new AtomicInteger();
        NativePtbBuilder.Result r = NativePtbBuilder.withStaleRetry(
            () -> calls.incrementAndGet() == 1 ? fail(STALE) : ok());
        assertTrue(r.granted);
        assertEquals(2, calls.get());
    }

    @Test
    public void aRealAbortIsNeverRetried() {
        // Retrying an abort would just pay for the same failure again.
        AtomicInteger calls = new AtomicInteger();
        NativePtbBuilder.Result r = NativePtbBuilder.withStaleRetry(() -> { calls.incrementAndGet(); return fail(ABORT); });
        assertFalse(r.granted);
        assertEquals(1, calls.get());
    }

    @Test
    public void successIsNotRepeated() {
        AtomicInteger calls = new AtomicInteger();
        NativePtbBuilder.withStaleRetry(() -> { calls.incrementAndGet(); return ok(); });
        assertEquals(1, calls.get());
    }

    @Test
    public void persistentStaleGivesUpAfterBoundedAttempts() {
        AtomicInteger calls = new AtomicInteger();
        NativePtbBuilder.Result r = NativePtbBuilder.withStaleRetry(() -> { calls.incrementAndGet(); return fail(STALE); });
        assertFalse(r.granted);
        assertEquals(NativePtbBuilder.STALE_ATTEMPTS, calls.get());
    }
}
