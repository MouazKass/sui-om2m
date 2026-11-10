package org.eclipse.om2m.sui.config;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.Properties;

import org.junit.Test;

/** F3: a node whose config predates the DENY keys gets the safe behaviour. */
public class DenyConfigDefaultsTest {

    private static Properties base() {
        Properties p = new Properties();
        p.setProperty("sui.cli.path", "sui");
        p.setProperty("sui.package.id", "0x88");
        p.setProperty("sui.identity.registry.id", "0x1");
        p.setProperty("sui.trust.registry.id", "0x2");
        p.setProperty("sui.policy.registry.id", "0x3");
        p.setProperty("sui.audit.trail.id", "0x4");
        p.setProperty("sui.node.address", "0x5");
        p.setProperty("mqtt.broker.url", "tcp://127.0.0.1:1883");
        return p;
    }

    @Test
    public void defaultsAreSafe() {
        SuiConfig c = SuiConfig.fromProperties(base());
        assertTrue("never pay for a DENY unless told to", c.precheckEnabled);
        assertEquals(10_000L, c.denyCacheTtlMs);
        assertEquals(1024, c.denyCacheMax);
        assertEquals(30, c.denyRateMax);
        assertEquals(60_000L, c.denyRateWindowMs);
        assertEquals("/var/lib/sui-om2m/deny-log.jsonl", c.denyLogPath);
        assertFalse("the v9-only on-chain flush is off by default", c.denyAuditFlushEnabled);
        assertEquals(15 * 60_000L, c.denyAuditFlushIntervalMs);
    }

    @Test
    public void flushIntervalIsFlooredAtTheContractMinimum() {
        Properties p = base();
        p.setProperty("sui.das.deny.audit.flush.interval.min", "1");
        assertEquals(300_000L, SuiConfig.fromProperties(p).denyAuditFlushIntervalMs);
    }

    @Test
    public void precheckCanBeTurnedOffExplicitly() {
        Properties p = base();
        p.setProperty("sui.das.precheck.enabled", "false");
        assertFalse(SuiConfig.fromProperties(p).precheckEnabled);
    }
}
