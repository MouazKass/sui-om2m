package org.eclipse.om2m.sui.config;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Properties;

/**
 * Reads runtime config from $OM2M_HOME/configuration/sui.properties.
 *
 * <p>The file is created on first install by the deploy script and
 * holds the Sui package ID (assigned by `sui client publish`), the
 * IDs of the shared registry objects, the path to the Sui CLI binary,
 * and the MQTT broker URL.
 */
public final class SuiConfig {

    public final String suiCliPath;
    public final String suiEnv;          // "testnet" by deployment choice
    public final String packageId;       // 0x... package ID after publish
    public final String identityRegistryId;
    public final String trustRegistryId;
    public final String policyRegistryId;
    public final String auditTrailId;
    public final String clusterId;       // failover cluster shared obj
    public final String suiClockId;      // always 0x6 on Sui
    public final String nodeAddress;     // this CSE's Sui address
    public final long   gasBudget;       // mist
    public final String mqttBrokerUrl;   // tcp://10.25.96.200:1883
    public final long   heartbeatPeriodMs;
    public final long   heartbeatTimeoutMs;
    public final long   leaseAnchorPeriodMs;

    private SuiConfig(Properties p) {
        this.suiCliPath          = req(p, "sui.cli.path");
        this.suiEnv              = p.getProperty("sui.env", "testnet");
        this.packageId           = req(p, "sui.package.id");
        this.identityRegistryId  = req(p, "sui.identity.registry.id");
        this.trustRegistryId     = req(p, "sui.trust.registry.id");
        this.policyRegistryId    = req(p, "sui.policy.registry.id");
        this.auditTrailId        = req(p, "sui.audit.trail.id");
        this.clusterId           = p.getProperty("sui.failover.cluster.id", "");
        this.suiClockId          = p.getProperty("sui.clock.id", "0x6");
        this.nodeAddress         = req(p, "sui.node.address");
        this.gasBudget           = Long.parseLong(p.getProperty("sui.gas.budget", "20000000"));
        this.mqttBrokerUrl       = req(p, "mqtt.broker.url");
        this.heartbeatPeriodMs   = Long.parseLong(p.getProperty("failover.heartbeat.period.ms",  "5000"));
        this.heartbeatTimeoutMs  = Long.parseLong(p.getProperty("failover.heartbeat.timeout.ms","15000"));
        this.leaseAnchorPeriodMs = Long.parseLong(p.getProperty("failover.lease.anchor.period.ms","600000"));
    }

    private static String req(Properties p, String key) {
        String v = p.getProperty(key);
        if (v == null || v.isBlank()) {
            throw new IllegalStateException("Missing required config key: " + key);
        }
        return v;
    }

    public static SuiConfig load() {
        String home = System.getenv().getOrDefault("OM2M_HOME", ".");
        Path file = Paths.get(home, "configuration", "sui.properties");
        Properties p = new Properties();
        try (InputStream in = Files.newInputStream(file)) {
            p.load(in);
        } catch (IOException e) {
            throw new IllegalStateException("Cannot read " + file, e);
        }
        return new SuiConfig(p);
    }
}
