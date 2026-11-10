package org.eclipse.om2m.sui.config;

import static org.junit.Assert.assertEquals;

import java.util.Properties;

import org.junit.Test;

/**
 * sui.package.original.id (the type-origin package id) must default to
 * sui.package.id, so a v8 node whose config lacks the key behaves exactly as
 * before; once set (v9), call targets and type names separate.
 */
public class PackageOriginalIdTest {

    static final String V8 = "0x88f0b0f7f3f4feb9a01e166567ca36a49ee149b9d260a0ac5cede95d89e962f1";
    static final String V9 = "0x9999999999999999999999999999999999999999999999999999999999999999";

    private static Properties base(String pkg) {
        Properties p = new Properties();
        p.setProperty("sui.cli.path", "sui");
        p.setProperty("sui.package.id", pkg);
        p.setProperty("sui.identity.registry.id", "0x1");
        p.setProperty("sui.trust.registry.id", "0x2");
        p.setProperty("sui.policy.registry.id", "0x3");
        p.setProperty("sui.audit.trail.id", "0x4");
        p.setProperty("sui.node.address", "0x5");
        p.setProperty("mqtt.broker.url", "tcp://127.0.0.1:1883");
        return p;
    }

    @Test
    public void absentKeyDefaultsToThePackageId() {
        SuiConfig c = SuiConfig.fromProperties(base(V8));
        assertEquals(V8, c.packageId);
        assertEquals(V8, c.packageOriginalId);
    }

    @Test
    public void blankKeyDefaultsToThePackageId() {
        Properties p = base(V8);
        p.setProperty("sui.package.original.id", "   ");
        assertEquals(V8, SuiConfig.fromProperties(p).packageOriginalId);
    }

    @Test
    public void afterTheUpgradeTheTwoIdsDiffer() {
        Properties p = base(V9);
        p.setProperty("sui.package.original.id", " " + V8 + " ");
        SuiConfig c = SuiConfig.fromProperties(p);
        assertEquals(V9, c.packageId);
        assertEquals(V8, c.packageOriginalId);
    }
}
