package org.eclipse.om2m.sui.failover;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/**
 * FM5 invariant: gas/funding exhaustion is detected and surfaced distinctly
 * from an ordinary on-chain rejection. isGasExhaustion(String) is a pure
 * package-private static predicate (mirrors the live FM5 demo where a drained
 * node logged "FM5 GAS EXHAUSTED" off the "no gas coin" error).
 */
public class FailoverManagerGasTest {

    @Test
    public void nullMessageIsNotGasExhaustion() {
        assertFalse(FailoverManager.isGasExhaustion(null));
    }

    @Test
    public void ordinaryRejectionIsNotGasExhaustion() {
        assertFalse(FailoverManager.isGasExhaustion(
            "MoveAbort: claim rejected, parent still live"));
        assertFalse(FailoverManager.isGasExhaustion(
            "InsufficientBalance is a different phrase"));
    }

    @Test
    public void noGasCoinMessageIsGasExhaustion() {
        assertTrue(FailoverManager.isGasExhaustion(
            "no gas coin with balance >= 20000000"));
        assertTrue(FailoverManager.isGasExhaustion(
            "...no gas coin..."));
    }
}
