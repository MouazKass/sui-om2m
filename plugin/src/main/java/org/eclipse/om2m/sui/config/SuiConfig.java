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
    public final String dasApocPath;     // CSE NOTIFY dispatch path for this DAS
    public final long   minTrust;        // trust gate fed into the PTB
    public final boolean useNativeRpc;   // true = bypass CLI, use BCS+RPC
    public final String  rpcUrl;          // fullnode RPC endpoint (testnet/mainnet)
    public final String  keystorePath;    // path to sui.keystore file
    // Provisioning maps: populated by the IN-CSE when tokens are minted.
    private final java.util.Map<String,String> addrIndex =
        new java.util.concurrent.ConcurrentHashMap<>();
    private final java.util.Map<String,String> tokenIndex =
        new java.util.concurrent.ConcurrentHashMap<>();

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
        this.dasApocPath         = p.getProperty("sui.das.apoc.path", "sui-das");
        this.minTrust            = Long.parseLong(p.getProperty("sui.min.trust", "50"));
        this.useNativeRpc        = Boolean.parseBoolean(p.getProperty("sui.use.native.rpc", "false"));
        this.rpcUrl              = p.getProperty("sui.rpc.url", "https://fullnode.testnet.sui.io:443");
        this.keystorePath        = p.getProperty("sui.keystore.path",
                                     System.getProperty("user.home") + "/.sui/sui_config/sui.keystore");
    }

    private static String req(Properties p, String key) {
        String v = p.getProperty(key);
        if (v == null || v.trim().isEmpty()) {
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
        SuiConfig cfg = new SuiConfig(p);
        // Optionally load originator->address and originator+resource->token
        // mappings from sui.mappings.properties (siblings to sui.properties).
        // Keys:
        //   addr.<originator>=<0x sui address>
        //   token.<originator>::<resource-id>=<0x token object id>
        Path mapFile = Paths.get(home, "configuration", "sui.mappings.properties");
        if (Files.exists(mapFile)) {
            Properties mp = new Properties();
            try (InputStream min = Files.newInputStream(mapFile)) {
                mp.load(min);
                for (String key : mp.stringPropertyNames()) {
                    String value = mp.getProperty(key);
                    if (key.startsWith("addr.")) {
                        cfg.registerAddress(key.substring(5), value);
                    } else if (key.startsWith("token.")) {
                        String rest = key.substring(6);
                        int sep = rest.indexOf("::");
                        if (sep > 0) {
                            String originator = rest.substring(0, sep);
                            String resourceId = rest.substring(sep + 2);
                            cfg.registerToken(originator, resourceId, value);
                        }
                    }
                }
            } catch (IOException e) {
                throw new IllegalStateException("Cannot read " + mapFile, e);
            }
        }
        return cfg;
    }

    // --- Originator -> Sui identity provisioning ---------------------------
    public void registerAddress(String originator, String suiAddress) {
        addrIndex.put(originator, suiAddress);
    }
    public void registerToken(String originator, String resourceId, String tokenObjectId) {
        tokenIndex.put(originator + "::" + resourceId, tokenObjectId);
    }
    public String resolveAddress(String originator) {
        return addrIndex.get(originator);
    }
    public String resolveToken(String originator, String resourceId) {
        return tokenIndex.get(originator + "::" + resourceId);
    }
}
