package org.eclipse.om2m.sui.trust;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.Test;

/**
 * GO9, refined for per-device identity: an address registered on-chain as an
 * end device (identity ROLE_AE = 3, e.g. an ESP32 sensor's signing key) must
 * never be admitted as a trust observer. Only IN-CSE (1) and MN-CSE (2) are.
 */
public class IdentityRoleMembershipTest {

    private static final String SELF = "0xself";

    /** Fake chain: addr -> role; absent = not registered; "down" = unreadable. */
    private static final class FakeChain implements IdentityRegistryMembers.ChainReader {
        final Map<String, Integer> roles = new HashMap<>();
        boolean down;
        final AtomicInteger reads = new AtomicInteger();

        @Override public Boolean isRegistered(String a) {
            reads.incrementAndGet();
            return down ? null : roles.containsKey(a);
        }
        @Override public Integer roleOf(String a) {
            reads.incrementAndGet();
            return down ? null : roles.get(a);
        }
    }

    @Test
    public void middlewareRolesAreMembers() {
        FakeChain c = new FakeChain();
        c.roles.put("0xin", 1);
        c.roles.put("0xmn", 2);
        IdentityRegistryMembers m = new IdentityRegistryMembers(c, SELF, 60_000);
        assertTrue(m.isMember("0xin"));
        assertTrue(m.isMember("0xmn"));
    }

    @Test
    public void aRegisteredEndDeviceIsNotAnObserver() {
        FakeChain c = new FakeChain();
        c.roles.put("0xesp", 3);
        IdentityRegistryMembers m = new IdentityRegistryMembers(c, SELF, 60_000);
        assertFalse(m.isMember("0xesp"));
    }

    @Test
    public void unknownRolesAndUnregisteredAreRejected() {
        FakeChain c = new FakeChain();
        c.roles.put("0xodd", 9);
        IdentityRegistryMembers m = new IdentityRegistryMembers(c, SELF, 60_000);
        assertFalse(m.isMember("0xodd"));
        assertFalse(m.isMember("0xnobody"));
    }

    @Test
    public void unreadableChainFailsClosedWithoutACachedAnswer() {
        FakeChain c = new FakeChain();
        c.roles.put("0xmn", 2);
        c.down = true;
        IdentityRegistryMembers m = new IdentityRegistryMembers(c, SELF, 60_000);
        assertFalse(m.isMember("0xmn"));
    }

    @Test
    public void answersAreCachedAndSelfNeedsNoRead() {
        FakeChain c = new FakeChain();
        c.roles.put("0xmn", 2);
        IdentityRegistryMembers m = new IdentityRegistryMembers(c, SELF, 60_000);
        assertTrue(m.isMember(SELF));
        assertEquals(0, c.reads.get());
        assertTrue(m.isMember("0xmn"));
        int after = c.reads.get();
        assertTrue(m.isMember("0xmn"));
        assertEquals(after, c.reads.get());
    }

    @Test
    public void roleHelper() {
        assertTrue(IdentityRegistryMembers.isMiddlewareRole(1));
        assertTrue(IdentityRegistryMembers.isMiddlewareRole(2));
        assertFalse(IdentityRegistryMembers.isMiddlewareRole(3));
        assertFalse(IdentityRegistryMembers.isMiddlewareRole(null));
    }
}
