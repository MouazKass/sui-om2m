package org.eclipse.om2m.sui.sdk;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/**
 * v10: step 4 of the access PTB. With sui.policy.device.binding=true the
 * builder calls policy::evaluate_with_device, which also takes the identity
 * registry, so a device-bound resource is granted only while its device is
 * registered. Without the flag the v8/v9 call is built unchanged.
 */
public class DevicePolicyStepTest {

    private static final byte[] PKG = BcsEncoder.hexTo32("0x" + repeat('a', 64));
    private static final int I_ID = 0, I_TRUST = 1, I_CLOCK = 4, I_POL = 7;

    private static String repeat(char c, int n) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < n; i++) b.append(c);
        return b.toString();
    }

    private static int inputIdx(SuiPtbEncoder.Arg a) {
        assertTrue("expected an input argument", a instanceof SuiPtbEncoder.InputArg);
        return ((SuiPtbEncoder.InputArg) a).idx;
    }

    @Test
    public void deviceBindingCallsEvaluateWithDeviceWithTheIdentityRegistry() {
        SuiPtbEncoder.MoveCall mc = NativePtbBuilder.policyStep(PKG, true, I_POL, I_TRUST, I_ID, I_CLOCK);
        assertEquals("policy", mc.module);
        assertEquals("evaluate_with_device", mc.function);
        assertEquals(5, mc.arguments.size());
        assertTrue("first argument is the TokenReceipt of cmd 2",
                   mc.arguments.get(0) instanceof SuiPtbEncoder.ResultArg);
        assertEquals(2, ((SuiPtbEncoder.ResultArg) mc.arguments.get(0)).idx);
        assertEquals(I_POL, inputIdx(mc.arguments.get(1)));
        assertEquals(I_TRUST, inputIdx(mc.arguments.get(2)));
        assertEquals("identity registry is the same input cmd 0 used", I_ID, inputIdx(mc.arguments.get(3)));
        assertEquals(I_CLOCK, inputIdx(mc.arguments.get(4)));
    }

    @Test
    public void withoutTheFlagTheV9CallIsUnchanged() {
        SuiPtbEncoder.MoveCall mc = NativePtbBuilder.policyStep(PKG, false, I_POL, I_TRUST, I_ID, I_CLOCK);
        assertEquals("evaluate", mc.function);
        assertEquals(4, mc.arguments.size());
        assertEquals(I_POL, inputIdx(mc.arguments.get(1)));
        assertEquals(I_TRUST, inputIdx(mc.arguments.get(2)));
        assertEquals(I_CLOCK, inputIdx(mc.arguments.get(3)));
    }

    @Test
    public void configFlagDefaultsOffAndIsFluent() {
        NativePtbBuilder.Config c = new NativePtbBuilder.Config("u", "0x1", "0x2", "0x3", "0x4", "0x5", "0x6", 1L, 0L);
        assertFalse(c.policyDeviceBinding);
        assertTrue(c.withPolicyDeviceBinding(true).policyDeviceBinding);
    }
}
