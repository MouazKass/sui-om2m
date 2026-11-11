package org.eclipse.om2m.sui.das;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

/** v10: the device-binding aborts are named in the DENY log. */
public class DeviceAbortNamesTest {

    private static String abort(int code) {
        return "MoveAbort(MoveLocation { module: ModuleId { address: 0x88, name: Identifier(\"policy\") },"
             + " function_name: Some(\"evaluate_with_device\"), instruction: 40 }, " + code + ")";
    }

    @Test
    public void namesEveryDeviceAbort() {
        assertEquals("policy::E_DEVICE_BOUND (abort 6)", AbortDecoder.decode(abort(6)));
        assertEquals("policy::E_DEVICE_NOT_REGISTERED (abort 7)", AbortDecoder.decode(abort(7)));
        assertEquals("policy::E_DEVICE_NOT_END_DEVICE (abort 8)", AbortDecoder.decode(abort(8)));
        assertEquals("policy::E_READER_NOT_ALLOWED (abort 9)", AbortDecoder.decode(abort(9)));
        assertEquals("policy::E_NOT_BOUND (abort 10)", AbortDecoder.decode(abort(10)));
    }
}
