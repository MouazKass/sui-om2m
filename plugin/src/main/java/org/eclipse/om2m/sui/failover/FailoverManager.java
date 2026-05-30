package org.eclipse.om2m.sui.failover;

import com.fasterxml.jackson.databind.JsonNode;
import org.eclipse.om2m.sui.config.SuiConfig;
import org.eclipse.om2m.sui.sdk.SuiCli;
import org.eclipse.om2m.sui.sdk.SuiCli.SuiCliException;
import org.eclipse.paho.client.mqttv3.IMqttDeliveryToken;
import org.eclipse.paho.client.mqttv3.MqttCallback;
import org.eclipse.paho.client.mqttv3.MqttClient;
import org.eclipse.paho.client.mqttv3.MqttConnectOptions;
import org.eclipse.paho.client.mqttv3.MqttException;
import org.eclipse.paho.client.mqttv3.MqttMessage;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;
import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

import java.util.List;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Implements the Trust-Gated Parent Failover state machine from slide 10.
 *
 * <p>This is the SECONDARY contribution — independent of the three-layer
 * framework. Steady state runs entirely off-chain over MQTT. The
 * blockchain is only invoked at the moment of takeover.
 *
 * <pre>
 *   OFF-CHAIN (steady state):
 *     - If this node IS the parent  : publish heartbeat every N ms.
 *     - If this node ISN'T the parent: subscribe and track last-seen.
 *
 *   ON-CHAIN (only when parent fails):
 *     - claim_parent(cluster, identity_reg, trust_reg, clock)
 *       -> Sui orders concurrent claims; one wins; trust gate enforced
 *          on-chain (slide 10 TRUST GATE box).
 *
 *   POST-TAKEOVER:
 *     - Resume MQTT heartbeats as the new parent.
 * </pre>
 */
public final class FailoverManager implements MqttCallback {

    private static final Log LOG = LogFactory.getLog(FailoverManager.class);

    private static final String HEARTBEAT_TOPIC_PREFIX = "om2m/failover/heartbeat/";

    private final SuiConfig cfg;
    private final SuiCli cli;
    private final ScheduledExecutorService scheduler =
        Executors.newScheduledThreadPool(2, r -> {
            Thread t = new Thread(r, "sui-failover");
            t.setDaemon(true);
            return t;
        });

    private MqttClient mqtt;
    private final AtomicLong lastHeartbeatMs = new AtomicLong(System.currentTimeMillis());
    private final AtomicReference<String> currentParentAddr = new AtomicReference<>("");
    private ScheduledFuture<?> heartbeatTask;
    private ScheduledFuture<?> watchdogTask;
    private ScheduledFuture<?> anchorTask;

    public FailoverManager(SuiConfig cfg, SuiCli cli) {
        this.cfg = cfg;
        this.cli = cli;
    }

    /** Start everything: MQTT, watchdog, heartbeat (if parent), lease anchor (if parent). */
    public void start() {
        if (cfg.clusterId == null || cfg.clusterId.trim().isEmpty()) {
            LOG.info("Failover disabled: no cluster ID in sui.properties");
            return;
        }

        // Initialise current_parent from on-chain state.
        refreshCurrentParent();
        connectMqtt();
        watchdogTask = scheduler.scheduleAtFixedRate(
            this::watchdogTick,
            cfg.heartbeatTimeoutMs,
            cfg.heartbeatPeriodMs,
            TimeUnit.MILLISECONDS);

        if (cfg.nodeAddress.equalsIgnoreCase(currentParentAddr.get())) {
            startParentDuties();
        }

        LOG.info("Failover manager started. parent=" + currentParentAddr.get() + " self=" + cfg.nodeAddress);
    }

    public void stop() {
        if (heartbeatTask != null) heartbeatTask.cancel(false);
        if (watchdogTask  != null) watchdogTask.cancel(false);
        if (anchorTask    != null) anchorTask.cancel(false);
        scheduler.shutdownNow();
        if (mqtt != null) {
            try { mqtt.disconnect(); } catch (MqttException ignored) {}
        }
    }

    // === MQTT ===
    private void connectMqtt() {
        try {
            String clientId = "sui-failover-" + cfg.nodeAddress + "-" + UUID.randomUUID();
            mqtt = new MqttClient(cfg.mqttBrokerUrl, clientId, new MemoryPersistence());
            MqttConnectOptions opts = new MqttConnectOptions();
            opts.setCleanSession(true);
            opts.setAutomaticReconnect(true);
            opts.setKeepAliveInterval(30);
            mqtt.setCallback(this);
            mqtt.connect(opts);
            mqtt.subscribe(HEARTBEAT_TOPIC_PREFIX + cfg.clusterId);
            LOG.info("MQTT connected to " + cfg.mqttBrokerUrl);
        } catch (MqttException e) {
            LOG.error("Failed to connect to MQTT broker", e);
        }
    }

    @Override
    public void messageArrived(String topic, MqttMessage message) {
        // Heartbeat payload format: "<parent-addr>|<epoch>|<ts-ms>"
        String payload = new String(message.getPayload());
        String[] parts = payload.split("\\|");
        if (parts.length < 3) return;
        String parentAddr = parts[0];

        // Only count heartbeats that come from the addr the chain
        // currently considers parent. Stops a malicious node from
        // suppressing failover by spamming fake beats.
        if (parentAddr.equalsIgnoreCase(currentParentAddr.get())) {
            lastHeartbeatMs.set(System.currentTimeMillis());
        }
    }

    @Override public void connectionLost(Throwable cause) {
        LOG.warn("MQTT connection lost: " + cause.getMessage());
    }
    @Override public void deliveryComplete(IMqttDeliveryToken token) { /* unused */ }

    // === Parent duties ===
    private void startParentDuties() {
        // Heartbeat publisher.
        heartbeatTask = scheduler.scheduleAtFixedRate(() -> {
            try {
                long now = System.currentTimeMillis();
                String payload = cfg.nodeAddress + "|0|" + now;
                MqttMessage m = new MqttMessage(payload.getBytes());
                m.setQos(0);
                if (mqtt != null && mqtt.isConnected()) {
                    mqtt.publish(HEARTBEAT_TOPIC_PREFIX + cfg.clusterId, m);
                }
            } catch (MqttException e) {
                LOG.warn("Heartbeat publish failed: " + e.getMessage());
            }
        }, 0, cfg.heartbeatPeriodMs, TimeUnit.MILLISECONDS);

        // Periodic lease anchor on-chain. Optional but it keeps the
        // chain's view of liveness fresh for any new joiners.
        anchorTask = scheduler.scheduleAtFixedRate(
            this::anchorLease,
            cfg.leaseAnchorPeriodMs,
            cfg.leaseAnchorPeriodMs,
            TimeUnit.MILLISECONDS);
    }

    private void anchorLease() {
        try {
            long newLeaseMs = cfg.leaseAnchorPeriodMs * 2L; // generous overlap
            List<String> argv = List.of(
                "client", "call",
                "--package",  cfg.packageId,
                "--module",   "failover",
                "--function", "renew_lease",
                "--args", cfg.clusterId, Long.toString(newLeaseMs), cfg.suiClockId,
                "--gas-budget", Long.toString(cfg.gasBudget));
            cli.runJson(argv);
        } catch (SuiCliException e) {
            LOG.warn("Lease anchor failed (will retry next period): " + e.getMessage());
        }
    }

    // === Watchdog ===
    private void watchdogTick() {
        long now = System.currentTimeMillis();
        long elapsed = now - lastHeartbeatMs.get();
        if (elapsed < cfg.heartbeatTimeoutMs) return;

        // We're a child node and the parent has gone quiet. Try to take
        // over. (If we are the parent, our own heartbeat publisher
        // updates lastHeartbeatMs implicitly via the broker, so we
        // never reach this branch unless our own MQTT broke too.)
        if (cfg.nodeAddress.equalsIgnoreCase(currentParentAddr.get())) {
            LOG.warn("Self-parent watchdog tripped — our own MQTT is broken");
            return;
        }
        LOG.warn("Parent silence detected (" + elapsed + " ms). Submitting Sui claim.");
        attemptClaim();
    }

    /** The on-chain part of slide 10. Calls failover::claim_parent. */
    private void attemptClaim() {
        List<String> argv = List.of(
            "client", "call",
            "--package",  cfg.packageId,
            "--module",   "failover",
            "--function", "claim_parent",
            "--args",
                cfg.clusterId,
                cfg.identityRegistryId,
                cfg.trustRegistryId,
                cfg.suiClockId,
            "--gas-budget", Long.toString(cfg.gasBudget));

        try {
            JsonNode resp = cli.runJson(argv);
            JsonNode status = resp.path("effects").path("status").path("status");
            if ("success".equalsIgnoreCase(status.asText())) {
                LOG.info("CLAIM ACCEPTED — we are now parent of cluster " + cfg.clusterId);
                refreshCurrentParent();
                if (cfg.nodeAddress.equalsIgnoreCase(currentParentAddr.get())) {
                    startParentDuties();
                }
            } else {
                // Could be E_LEASE_STILL_VALID (someone else got there
                // first), E_TRUST_BELOW_GATE, or E_NOT_REGISTERED.
                String err = resp.path("effects").path("status").path("error").asText("unknown");
                LOG.info("Claim rejected on-chain: " + err);
                // Refresh in case someone else won.
                refreshCurrentParent();
                // Reset the watchdog so we don't hammer the chain.
                lastHeartbeatMs.set(System.currentTimeMillis());
            }
        } catch (SuiCliException e) {
            LOG.warn("Claim submission failed: " + e.getMessage());
        }
    }

    /** Read the cluster object and cache current_parent. */
    private void refreshCurrentParent() {
        List<String> argv = List.of("client", "object", cfg.clusterId);
        try {
            JsonNode resp = cli.runJson(argv);
            String parent = resp
                .path("content").path("fields").path("current_parent")
                .asText("");
            if (!parent.isEmpty()) {
                currentParentAddr.set(parent);
            }
        } catch (SuiCliException e) {
            LOG.warn("Failed to read cluster state: " + e.getMessage());
        }
    }
}
