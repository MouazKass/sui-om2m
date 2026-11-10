package org.eclipse.om2m.sui.failover;

import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.IOException;
import java.math.BigInteger;

import org.eclipse.om2m.sui.sdk.GasPlan;
import org.eclipse.om2m.sui.sdk.SuiPtbEncoder;
import org.junit.Test;

/** FM5 must still fire when neither coins nor the address balance can pay. */
public class GasExhaustionMarkerTest {

    @Test
    public void gasPlanShortfallIsRecognisedByFm5() {
        GasPlan.Chain empty = new GasPlan.Chain() {
            @Override public SuiPtbEncoder.ObjectRef coinCovering(long b) { return null; }
            @Override public BigInteger addressBalance() { return BigInteger.ONE; }
            @Override public long epoch() { return 1; }
            @Override public byte[] chainId() { return new byte[32]; }
        };
        try {
            GasPlan.choose(empty, 1_000, GasPlan.Mode.AUTO, 1);
            fail("must throw");
        } catch (IOException e) {
            assertTrue(e.getMessage(), FailoverManager.isGasExhaustion(e.getMessage()));
        }
    }
}
