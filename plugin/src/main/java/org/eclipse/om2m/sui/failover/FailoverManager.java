package org.eclipse.om2m.sui.failover;

import com.fasterxml.jackson.databind.JsonNode;
import org.eclipse.om2m.sui.config.SuiConfig;
import org.eclipse.om2m.sui.trust.TrustScoringEngine;
import org.eclipse.om2m.sui.trust.BehaviourObserver;
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
    private volatile org.eclipse.om2m.sui.sdk.NativePtbBuilder nativePtb;
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
    private ScheduledFuture<?> parentSelfCheckTask;

    // FM5: surface gas-exhaustion distinctly from ordinary claim rejection.
    private final java.util.concurrent.atomic.AtomicLong gasFailureCount =
        new java.util.concurrent.atomic.AtomicLong(0);
    private volatile long lastGasFailureMs = 0L;
    private volatile String lastGasFailureDetail = null;

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

        LOG.info("Failover manager started. parent=" + currentParentAddr.get() + " self=" + cfg.nodeAddress + " parentPoa=[" + cfg.parentPoa + "] poaFile=[" + cfg.poaFilePath + "]");
    }

    public void stop() {
        if (heartbeatTask != null) heartbeatTask.cancel(false);
        if (watchdogTask  != null) watchdogTask.cancel(false);
        if (anchorTask    != null) anchorTask.cancel(false);
        if (parentSelfCheckTask != null) parentSelfCheckTask.cancel(false);
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
            long localNow = System.currentTimeMillis();
            lastHeartbeatMs.set(localNow);
            try {
                BehaviourObserver obs = TrustScoringEngine.activeObserver();
                if (obs != null) {
                    obs.recordHeartbeat(parentAddr, localNow);
                    // Clock drift: how far the peer thinks "now" is from our "now".
                    // payload[2] is the peer's ts-ms from the heartbeat publish.
                    try {
                        long peerTs = Long.parseLong(parts[2]);
                        obs.recordClockDrift(parentAddr, (double) (localNow - peerTs), localNow);
                    } catch (NumberFormatException _nfe) { /* malformed ts, ignore */ }
                }
            } catch (Throwable _t) { /* never let trust break failover */ }
        }
    }

    @Override public void connectionLost(Throwable cause) {
        LOG.warn("MQTT connection lost: " + cause.getMessage());
    }
    @Override public void deliveryComplete(IMqttDeliveryToken token) { /* unused */ }

    // === Parent duties ===
    private synchronized void startParentDuties() {
        // Idempotency guard: cancel any existing tasks before (re)scheduling.
        if (heartbeatTask != null) { heartbeatTask.cancel(false); heartbeatTask = null; }
        if (anchorTask    != null) { anchorTask.cancel(false);    anchorTask    = null; }
        if (parentSelfCheckTask != null) { parentSelfCheckTask.cancel(false); parentSelfCheckTask = null; }
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

        // FM3: while we are parent, periodically confirm the chain still
        // names us. If it doesn't, refreshCurrentParent() -> stopParentDuties().
        parentSelfCheckTask = scheduler.scheduleAtFixedRate(() -> {
            try {
                if (cfg.nodeAddress.equalsIgnoreCase(currentParentAddr.get())) {
                    refreshCurrentParent();
                }
            } catch (Throwable _t) { /* never let the self-check kill the scheduler */ }
        }, cfg.parentSelfCheckPeriodMs, cfg.parentSelfCheckPeriodMs, TimeUnit.MILLISECONDS);
    }

    /**
     * FM3: tear down parent duties when this node has been deposed.
     * Cancels the heartbeat publisher and the lease anchor so the node
     * stops asserting parenthood on MQTT and on-chain. Idempotent.
     */
    // FM5: a gas-coin shortfall surfaces from pickGasCoin as
    // "no gas coin with balance >= ..." inside Result.error, with a null digest
    // (tx never submitted). Detect that and raise a distinct, queryable signal
    // instead of logging it as an ordinary on-chain rejection.
    private boolean isGasExhaustion(String msg) {
        return msg != null && msg.contains("no gas coin");
    }

    private void surfaceGasExhaustion(String detail) {
        long n = gasFailureCount.incrementAndGet();
        lastGasFailureMs = System.currentTimeMillis();
        lastGasFailureDetail = detail;
        LOG.error("FM5 GAS EXHAUSTED - claim could not be funded (need a SUI coin"
                + " with balance >= gasBudget=" + cfg.gasBudget + "). This node cannot"
                + " participate in failover until its wallet is refunded."
                + " failures=" + n + " detail=" + detail);
    }

    /** FM5: queryable gas-failure signal for monitoring/alerting. */
    public long getGasFailureCount() { return gasFailureCount.get(); }
    public long getLastGasFailureMs() { return lastGasFailureMs; }
    public String getLastGasFailureDetail() { return lastGasFailureDetail; }

    private synchronized void stopParentDuties() {
        boolean wasParent = false;
        if (heartbeatTask != null) { heartbeatTask.cancel(false); heartbeatTask = null; wasParent = true; }
        if (anchorTask    != null) { anchorTask.cancel(false);    anchorTask    = null; wasParent = true; }
        if (parentSelfCheckTask != null) { parentSelfCheckTask.cancel(false); parentSelfCheckTask = null; }
        if (wasParent) {
            lastHeartbeatMs.set(System.currentTimeMillis());
            LOG.info("Parent duties stopped (deposed): heartbeat + lease anchor cancelled.");
        }
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
            // FM3b: before assuming our own MQTT is broken, re-check the chain.
            // We may have been deposed while still believing we are parent;
            // refreshCurrentParent() will detect that and fire stopParentDuties().
            refreshCurrentParent();
            if (cfg.nodeAddress.equalsIgnoreCase(currentParentAddr.get())) {
                LOG.warn("Self-parent watchdog tripped — our own MQTT is broken");
            }
            return;
        }
        LOG.warn("Parent silence detected (" + elapsed + " ms). Submitting Sui claim.");
        attemptClaim();
    }

    /** The on-chain part of slide 10. Calls failover::claim_parent. */
        private void attemptClaim() {
        // Submit off-thread so watchdog stays responsive
        scheduler.submit(() -> {
            try {
                org.eclipse.om2m.sui.sdk.NativePtbBuilder n = nativePtb;
                if (n == null) {
                    synchronized (this) {
                        n = nativePtb;
                        if (n == null) {
                            org.eclipse.om2m.sui.sdk.NativePtbBuilder.Config nc =
                                new org.eclipse.om2m.sui.sdk.NativePtbBuilder.Config(
                                    cfg.rpcUrl, cfg.packageId,
                                    cfg.identityRegistryId, cfg.trustRegistryId,
                                    cfg.policyRegistryId, cfg.auditTrailId,
                                    cfg.suiClockId, cfg.gasBudget, cfg.minTrust);
                            n = new org.eclipse.om2m.sui.sdk.NativePtbBuilder(
                                nc, java.nio.file.Paths.get(cfg.keystorePath));
                            nativePtb = n;
                        }
                    }
                }
                org.eclipse.om2m.sui.sdk.NativePtbBuilder.Result r =
                    n.claimParent(cfg.nodeAddress, cfg.clusterId);
                if (r.granted) {
                    LOG.info("CLAIM ACCEPTED — we are now parent of cluster " + cfg.clusterId
                             + " digest=" + r.digest + " (" + r.elapsedMs + " ms)");
                    currentParentAddr.set(cfg.nodeAddress);
                    // Broadcast our HTTP PoA to followers via the Cluster dynamic field.
                    // OM2M IN-CSE PoA convention is http://<host>:<port>/
                    String poa = cfg.parentPoa;
                    if (poa != null && !poa.isEmpty()) {
                        org.eclipse.om2m.sui.sdk.NativePtbBuilder.Result pr =
                            n.setParentPoa(cfg.nodeAddress, cfg.clusterId, poa);
                        if (pr.granted) {
                            LOG.info("PoA published on-chain: " + poa + " digest=" + pr.digest + " (" + pr.elapsedMs + " ms)");
                        } else {
                            LOG.warn("Failed to publish PoA on-chain: " + pr.error);
                        }
                        // Also write to local file (for parent's own local MN-CSE container, if any)
                        try {
                            String fp = cfg.poaFilePath;
                            if (fp != null && !fp.isEmpty()) {
                                java.nio.file.Path target = java.nio.file.Paths.get(fp);
                                if (target.getParent() != null) java.nio.file.Files.createDirectories(target.getParent());
                                java.nio.file.Files.write(target, poa.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                                LOG.info("PoA written locally to " + fp);
                            }
                        } catch (Exception fe) {
                            LOG.warn("Local PoA write failed: " + fe.getMessage());
                        }
                        // Trigger role-switch to IN-CSE
                        invokeRoleSwitch("in", null);
                    }
                    startParentDuties();
                } else if (isGasExhaustion(r.error)) {
                    // FM5: funding failure, not an ordinary rejection. Surface it.
                    surfaceGasExhaustion(r.error);
                    refreshCurrentParent();
                } else {
                    LOG.info("Claim rejected on-chain: " + r.error + " (digest=" + r.digest + ")");
                    refreshCurrentParent();
                }
            } catch (Exception e) {
                if (isGasExhaustion(e.getMessage())) {
                    surfaceGasExhaustion(e.getMessage());
                } else {
                    LOG.warn("Claim submission failed: " + e.getMessage());
                }
            }
        });
    }

    /** Read the cluster object and cache current_parent. */
    private void refreshCurrentParent() {
        // Direct RPC fetch — avoid blocking the OSGi Activator on a CLI fork.
        try {
            com.fasterxml.jackson.databind.ObjectMapper m =
                new com.fasterxml.jackson.databind.ObjectMapper();
            com.fasterxml.jackson.databind.node.ObjectNode req = m.createObjectNode();
            req.put("jsonrpc", "2.0");
            req.put("id", 1);
            req.put("method", "sui_getObject");
            com.fasterxml.jackson.databind.node.ArrayNode params = req.putArray("params");
            params.add(cfg.clusterId);
            com.fasterxml.jackson.databind.node.ObjectNode opts = params.addObject();
            opts.put("showContent", true);

            java.net.HttpURLConnection conn =
                (java.net.HttpURLConnection) new java.net.URL(cfg.rpcUrl).openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(5000);
            conn.setReadTimeout(5000);
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setDoOutput(true);
            byte[] body = m.writeValueAsString(req).getBytes(java.nio.charset.StandardCharsets.UTF_8);
            conn.getOutputStream().write(body);
            int rc = conn.getResponseCode();
            if (rc < 200 || rc >= 300) {
                LOG.warn("refreshCurrentParent HTTP " + rc);
                return;
            }
            java.io.InputStream in = conn.getInputStream();
            java.io.ByteArrayOutputStream baos = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[8192]; int n;
            while ((n = in.read(buf)) > 0) baos.write(buf, 0, n);
            com.fasterxml.jackson.databind.JsonNode resp = m.readTree(baos.toByteArray());
            String parent = resp.path("result").path("data").path("content")
                .path("fields").path("current_parent").asText("");
            if (!parent.isEmpty()) {
                String previous = currentParentAddr.get();
                currentParentAddr.set(parent);
                LOG.info("Cluster current parent = " + parent);
                // Detect parent change. If it's not us, read the new PoA from
                // chain and persist it for follower bootstrapping.
                boolean changed = (previous == null) || previous.isEmpty()
                        || !previous.equalsIgnoreCase(parent);
                if (changed && !parent.equalsIgnoreCase(cfg.nodeAddress)) {
                    // FM3: the chain now names someone else as parent. If we were
                    // running parent duties, tear them down before switching role.
                    stopParentDuties();  // FM3
                    onParentChanged(parent);
                }
            } else {
                LOG.info("Cluster has no current parent yet");
            }
        } catch (Exception e) {
            LOG.warn("Failed to read cluster state: " + e.getMessage());
        }
    }

    /** Called when this follower notices the parent has changed (and it's not us). */
    private void onParentChanged(String newParent) {
        // Run off-thread; involves an RPC call.
        scheduler.submit(() -> {
            try {
                org.eclipse.om2m.sui.sdk.NativePtbBuilder n = nativePtb;
                if (n == null) {
                    synchronized (this) {
                        n = nativePtb;
                        if (n == null) {
                            org.eclipse.om2m.sui.sdk.NativePtbBuilder.Config nc =
                                new org.eclipse.om2m.sui.sdk.NativePtbBuilder.Config(
                                    cfg.rpcUrl, cfg.packageId,
                                    cfg.identityRegistryId, cfg.trustRegistryId,
                                    cfg.policyRegistryId, cfg.auditTrailId,
                                    cfg.suiClockId, cfg.gasBudget, cfg.minTrust);
                            n = new org.eclipse.om2m.sui.sdk.NativePtbBuilder(
                                nc, java.nio.file.Paths.get(cfg.keystorePath));
                            nativePtb = n;
                        }
                    }
                }
                // Retry up to 5 times with backoff (parent may not have published yet)
                String poa = null;
                for (int attempt = 1; attempt <= 5; attempt++) {
                    poa = n.fetchParentPoa(cfg.clusterId);
                    if (poa != null && !poa.isEmpty()) break;
                    LOG.info("PoA not yet on chain (attempt " + attempt + "/5), retrying...");
                    Thread.sleep(2000L * attempt);
                }
                if (poa == null || poa.isEmpty()) {
                    LOG.warn("New parent " + newParent + " did not publish PoA after 5 attempts");
                    return;
                }
                LOG.info("New parent PoA: " + poa);
                // Persist to file for the MN-CSE container's startup wrapper.
                String path = cfg.poaFilePath;
                if (path != null && !path.isEmpty()) {
                    java.nio.file.Path target = java.nio.file.Paths.get(path);
                    java.nio.file.Files.createDirectories(target.getParent());
                    java.nio.file.Files.write(target,
                        poa.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                    LOG.info("PoA written to " + path);
                    // Trigger role-switch to MN-CSE
                    invokeRoleSwitch("mn", poa);
                }
            } catch (Exception e) {
                LOG.warn("onParentChanged failed: " + e.getMessage());
            }
        });
    }

    /** Invoke /root/role-switch.sh role POA. Async via Runtime.exec. */
    private void invokeRoleSwitch(String role, String poa) {
        if (!cfg.roleSwitchEnabled) {
            LOG.info("[role-switch] disabled in config; skipping (role=" + role + ")");
            return;
        }
        try {
            String[] cmd = (poa == null)
                ? new String[]{"/root/role-switch.sh", role}
                : new String[]{"/root/role-switch.sh", role, poa};
            LOG.info("[role-switch] invoking: " + String.join(" ", cmd));
            ProcessBuilder pb = new ProcessBuilder(cmd);
            pb.redirectErrorStream(true);
            Process p = pb.start();
            // Don't block — log output asynchronously
            new Thread(() -> {
                try (java.io.BufferedReader r = new java.io.BufferedReader(
                        new java.io.InputStreamReader(p.getInputStream()))) {
                    String line;
                    while ((line = r.readLine()) != null) {
                        LOG.info("[role-switch] " + line);
                    }
                } catch (Exception ignored) {}
            }, "role-switch-out").start();
        } catch (Exception e) {
            LOG.warn("[role-switch] invocation failed: " + e.getMessage());
        }
    }
}
