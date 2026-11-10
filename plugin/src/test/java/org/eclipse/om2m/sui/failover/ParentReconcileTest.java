package org.eclipse.om2m.sui.failover;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/**
 * The chain decides who is parent; the plugin must follow it however the node
 * came to be named.
 *
 * Observed live on 2026-11-10 (proofs/06_failover.sh, run 1): rpi2 became
 * parent through a claim signed outside its plugin. Its plugin never started
 * parent duties, the 60 s claim lease lapsed and was never anchored, and no
 * node noticed, because the deposed parent's presence beats kept every
 * watchdog quiet. The same happens when a claim lands although the client saw
 * an error or timeout.
 */
public class ParentReconcileTest {

    private static final String SELF  = "0x4be6060abaff0b4b6b7229558887f5f054cbe7d9836ba56eff35d848e13dc1f5";
    private static final String OTHER = "0x27dacda1bdcb3fb8dc2a4b0d77b420deea5bb43d1047592ddadb19f35764ea10";

    @Test
    public void namedByTheChainWithoutDutiesTakesThemUp() {
        assertTrue(FailoverManager.shouldTakeUpParentDuties(SELF, SELF, false));
    }

    @Test
    public void addressComparisonIgnoresCase() {
        assertTrue(FailoverManager.shouldTakeUpParentDuties(SELF.toUpperCase().replace("0X", "0x"), SELF, false));
    }

    @Test
    public void dutiesAlreadyRunningAreNotRestarted() {
        assertFalse(FailoverManager.shouldTakeUpParentDuties(SELF, SELF, true));
    }

    @Test
    public void anotherParentNeverStartsDuties() {
        assertFalse(FailoverManager.shouldTakeUpParentDuties(OTHER, SELF, false));
        assertFalse(FailoverManager.shouldTakeUpParentDuties(null, SELF, false));
        assertFalse(FailoverManager.shouldTakeUpParentDuties("", SELF, false));
    }

    // --- follower PoA reconciliation -------------------------------------
    // Right after a takeover the on-chain PoA still holds the deposed
    // parent's URL; followers that read it then must correct it later.

    @Test
    public void aChangedPoaIsPersisted() {
        assertTrue(FailoverManager.poaNeedsUpdate("http://10.25.96.201:8282/", "http://10.25.96.203:8282/"));
        assertTrue(FailoverManager.poaNeedsUpdate("http://10.25.96.201:8282/", null));
    }

    @Test
    public void anUnchangedOrMissingPoaIsNotRewritten() {
        assertFalse(FailoverManager.poaNeedsUpdate("http://10.25.96.201:8282/", "http://10.25.96.201:8282/"));
        assertFalse(FailoverManager.poaNeedsUpdate(null, "http://10.25.96.201:8282/"));
        assertFalse(FailoverManager.poaNeedsUpdate("", "http://10.25.96.201:8282/"));
    }
}
