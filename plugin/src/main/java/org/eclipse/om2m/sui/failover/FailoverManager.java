package org.eclipse.om2m.sui.failover;

import org.eclipse.om2m.sui.trust.SignedBeacon;
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
    // B9: the heartbeat publisher is a NODE-level duty, not a parent-only one.
    // Non-parent nodes have to beat as well, otherwise there is nothing for
    // their peers to record and their heartbeat health stays 0 forever. The
    // beat carries no authority: followers only feed the watchdog from the
    // address the chain names parent (see messageArrived).
    private ScheduledFuture<?> presenceTask;
    private ScheduledFuture<?> watchdogTask;
    private ScheduledFuture<?> anchorTask;
    private ScheduledFuture<?> parentSelfCheckTask;
    private ScheduledFuture<?> chainSyncTask;

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

        // B9: beat unconditionally, parent or not, so every node's heartbeat
        // health is observable by its peers.
        startPresenceBeats();

        // refreshCurrentParent() above already starts duties when the chain
        // names us; this covers a read that failed at startup.
        if (cfg.nodeAddress.equalsIgnoreCase(currentParentAddr.get()) && !parentDutiesRunning()) {
            startParentDuties();
        }

        // Chain sync, on EVERY node. The chain decides who is parent; each
        // node re-reads it on a fixed cadence (a free GraphQL read) instead of
        // only when its heartbeat watchdog trips. Without this, a node that
        // became parent on-chain other than through its own successful claim
        // (a claim that landed although the client saw an error or timeout,
        // or a claim signed outside the plugin) never started parent duties:
        // its 60 s claim lease lapsed and nobody noticed, because the old
        // parent's presence beats kept every follower's watchdog quiet.
        // Observed live 2026-11-10 (proofs/06_failover.sh run 1).
        chainSyncTask = scheduler.scheduleAtFixedRate(() -> {
            try {
                refreshCurrentParent();
            } catch (Throwable _t) { /* never let the sync kill the scheduler */ }
        }, cfg.parentSelfCheckPeriodMs, cfg.parentSelfCheckPeriodMs, TimeUnit.MILLISECONDS);

        LOG.info("Failover manager started. parent=" + currentParentAddr.get() + " self=" + cfg.nodeAddress + " parentPoa=[" + cfg.parentPoa + "] poaFile=[" + cfg.poaFilePath + "]");
    }

    public void stop() {
        if (presenceTask != null) presenceTask.cancel(false);
        if (watchdogTask  != null) watchdogTask.cancel(false);
        if (anchorTask    != null) anchorTask.cancel(false);
        if (parentSelfCheckTask != null) parentSelfCheckTask.cancel(false);
        if (chainSyncTask != null) chainSyncTask.cancel(false);
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
            // Per-origin topics (see TrustGossip): subscribe to every node's
            // subtree, publish only on our own, so the mesh never re-forwards.
            mqtt.subscribe(HEARTBEAT_TOPIC_PREFIX + cfg.clusterId + "/+");
            LOG.info("MQTT connected to " + cfg.mqttBrokerUrl);
        } catch (MqttException e) {
            LOG.error("Failed to connect to MQTT broker", e);
        }
    }

    /**
     * Heartbeat payload format: {@code "<sender-addr>|<epoch>|<ts-ms>"}.
     *
     * <p><b>B9.</b> The two things this method does are now separated, because
     * they need different trust models:
     * <ul>
     *   <li><i>Failover liveness</i> ({@link #lastHeartbeatMs}) still only
     *       accepts beats from the address the chain currently names parent.
     *       That gate is a security property: without it any node could
     *       suppress failover forever by spamming fake beats.</li>
     *   <li><i>Trust telemetry</i> (heartbeat health + clock drift) is now
     *       recorded for <b>every</b> middleware node that beats. Gating it on
     *       the parent address meant every non-parent node's heartbeat health
     *       was pinned at 0.0 for its whole lifetime, which alone cost it 25 of
     *       100 trust points under the B11/B12 weights and capped it below the
     *       top tier no matter how well it behaved.</li>
     * </ul>
     * Note the sender address here is self-declared and unauthenticated, so it
     * only ever feeds the trust signals (where a liar can at most forge beats
     * attributed to itself, i.e. improve its own apparent health, and the peer
     * median in {@code TrustScoringEngine.aggregateAndScore} is what decides) --
     * never the failover decision.
     */
    @Override
    public void messageArrived(String topic, MqttMessage message) {
        // Only signed beats, bound to the key of the address they name, count
        // for anything (see SignedBeacon). Unsigned or forged beats are dropped.
        SignedBeacon.Verified v = SignedBeacon.verify(
            new String(message.getPayload(), java.nio.charset.StandardCharsets.UTF_8));
        if (v == null) return;
        String senderAddr = v.sender;
        long localNow = System.currentTimeMillis();

        // Failover liveness: only the chain-designated parent's beats count,
        // and only FRESH ones, so a captured or looped beat cannot keep a dead
        // parent looking alive.
        if (countsForLiveness(v, currentParentAddr.get(), localNow, cfg.heartbeatTimeoutMs)) {
            lastHeartbeatMs.set(localNow);
        }

        // B9: trust telemetry from every middleware node, parent or not.
        try {
            BehaviourObserver obs = TrustScoringEngine.activeObserver();
            if (obs != null) {
                obs.recordHeartbeat(senderAddr, localNow);
                // Clock drift: how far the peer thinks "now" is from our "now".
                obs.recordClockDrift(senderAddr, (double) (localNow - v.tsMs), localNow);
            }
        } catch (Throwable _t) { /* never let trust break failover */ }
    }

    /**
     * Pure liveness rule, kept static so it is unit-testable without MQTT: a beat
     * keeps the parent alive only if it is verified, comes from the address the
     * chain names as parent, and its own timestamp is within {@code maxSkewMs} of
     * local time. The freshness bound turns any replayed or bridge-looped beat
     * into a no-op once it is older than the heartbeat timeout.
     */
    static boolean countsForLiveness(SignedBeacon.Verified v, String currentParent,
                                     long localNowMs, long maxSkewMs) {
        return v != null && currentParent != null
            && v.sender.equalsIgnoreCase(currentParent)
            && Math.abs(localNowMs - v.tsMs) <= maxSkewMs;
    }

    @Override public void connectionLost(Throwable cause) {
        LOG.warn("MQTT connection lost: " + cause.getMessage());
    }
    @Override public void deliveryComplete(IMqttDeliveryToken token) { /* unused */ }

    /**
     * B9: node-level heartbeat ("presence") publisher. Every node beats, so
     * every node's heartbeat health is measurable by its peers. Started once in
     * {@link #start()} and never cancelled by {@link #stopParentDuties()} --
     * a beat asserts "I am alive", not "I am parent"; who is parent is decided
     * by the chain and read back in {@link #refreshCurrentParent()}.
     */
    private synchronized void startPresenceBeats() {
        if (presenceTask != null) { presenceTask.cancel(false); presenceTask = null; }
        presenceTask = scheduler.scheduleAtFixedRate(() -> {
            // Catch Throwable: scheduleAtFixedRate silently cancels a task
            // whose run() throws, which would end this node's heartbeats for
            // good and get it deposed after one bad tick.
            try {
                SignedBeacon b = beacon();
                if (b == null) return;   // cannot sign -> cannot assert liveness (fails safe)
                String payload = b.beat(0L, System.currentTimeMillis());
                MqttMessage m = new MqttMessage(payload.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                m.setQos(0);
                if (mqtt != null && mqtt.isConnected()) {
                    mqtt.publish(HEARTBEAT_TOPIC_PREFIX + cfg.clusterId + "/"
                                 + cfg.nodeAddress.toLowerCase(), m);
                }
            } catch (Throwable t) {
                LOG.warn("Heartbeat publish failed: " + t);
            }
        }, 0, cfg.heartbeatPeriodMs, TimeUnit.MILLISECONDS);
    }

    private volatile SignedBeacon beacon;
    private volatile boolean beaconMissingLogged;

    /** This node's heartbeat signer, loaded once from the node keystore. */
    private SignedBeacon beacon() {
        SignedBeacon b = beacon;
        if (b == null) {
            b = SignedBeacon.fromKeystore(cfg.keystorePath, cfg.nodeAddress);
            if (b == null) {
                if (!beaconMissingLogged) {
                    beaconMissingLogged = true;
                    LOG.error("Heartbeat signing key unavailable (" + cfg.keystorePath
                              + " must hold the key for " + cfg.nodeAddress + "). This node"
                              + " cannot assert liveness, so peers will treat it as silent.");
                }
                return null;
            }
            beacon = b;
        }
        return b;
    }

    // === Parent duties ===
    private synchronized void startParentDuties() {
        // Idempotency guard: cancel any existing tasks before (re)scheduling.
        if (anchorTask    != null) { anchorTask.cancel(false);    anchorTask    = null; }
        if (parentSelfCheckTask != null) { parentSelfCheckTask.cancel(false); parentSelfCheckTask = null; }
        // NB (B9): the heartbeat publisher is no longer a parent duty -- see
        // startPresenceBeats(), scheduled for every node in start().

        // Periodic lease anchor on-chain. The FIRST anchor runs immediately:
        // after any downtime the lease has usually expired, and waiting a full
        // period would leave a window in which a peer can legitimately claim.
        // Each anchor also re-checks the advertised PoA (publishPoaIfNeeded).
        anchorTask = scheduler.scheduleAtFixedRate(
            this::anchorLease,
            0L,
            cfg.leaseAnchorPeriodMs,
            TimeUnit.MILLISECONDS);

        // FM3 (confirming the chain still names us) is covered by the
        // chain-sync task scheduled in start(), which runs on every node.
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
    static boolean isGasExhaustion(String msg) {
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
        if (anchorTask    != null) { anchorTask.cancel(false);    anchorTask    = null; wasParent = true; }
        if (parentSelfCheckTask != null) { parentSelfCheckTask.cancel(false); parentSelfCheckTask = null; }
        // B9: the presence beat deliberately keeps running. It no longer asserts
        // parenthood (followers only credit beats from the chain's
        // current_parent), and stopping it would blank this node's heartbeat
        // health in every peer's trust score the moment it was deposed.
        if (wasParent) {
            lastHeartbeatMs.set(System.currentTimeMillis());
            LOG.info("Parent duties stopped (deposed): lease anchor + self-check cancelled"
                     + " (presence heartbeat continues).");
        }
    }

    private synchronized boolean parentDutiesRunning() {
        return anchorTask != null && !anchorTask.isDone();
    }

    /**
     * The chain is the source of truth for the parent role: if it names this
     * node and parent duties are not running, they must be started, however
     * the node came to be named (pure, unit-tested in ParentReconcileTest).
     */
    static boolean shouldTakeUpParentDuties(String chainParent, String self, boolean dutiesRunning) {
        return chainParent != null && self != null && !dutiesRunning
            && chainParent.equalsIgnoreCase(self);
    }

    /** Mirrors failover::MAX_LEASE_MS (A10). renew_lease aborts above it. */
    static final long MAX_LEASE_MS = 3_600_000L;

    /**
     * Lease anchor. Runs on the native path (see NativePtbBuilder.renewLease
     * for why it no longer shells out to the sui CLI). Catches Throwable:
     * scheduleAtFixedRate silently cancels a task whose run() throws, which
     * would stop all future anchors with no error after the first failure.
     */
    private void anchorLease() {
        try {
            // Generous overlap, but never above Move's bound, or every renewal
            // would abort with E_LEASE_TOO_LONG.
            long newLeaseMs = Math.min(cfg.leaseAnchorPeriodMs * 2L, MAX_LEASE_MS);
            org.eclipse.om2m.sui.sdk.NativePtbBuilder.Result r =
                nativePtb().renewLease(cfg.nodeAddress, cfg.clusterId, newLeaseMs);
            if (r.granted) {
                LOG.info("Lease anchored for " + newLeaseMs + " ms digest=" + r.digest
                         + " (" + r.elapsedMs + " ms)");
            } else if (isGasExhaustion(r.error)) {
                surfaceGasExhaustion(r.error);
            } else {
                LOG.warn("Lease anchor failed: " + r.error);
                scheduleAnchorRetry();
            }
            if (r.granted) anchorRetries = 0;
            // Keep the advertised PoA correct; this is a cheap read when it already is.
            publishPoaIfNeeded();
        } catch (Throwable t) {
            LOG.warn("Lease anchor error: " + t);
            scheduleAnchorRetry();
        }
    }

    /**
     * A failed anchor must be retried within seconds, not at the next 10 min
     * period: claim_parent grants only a short lease, so a new parent whose
     * first anchor fails loses the role to a peer before the next period
     * (observed live on 2026-11-10). Retries every ANCHOR_RETRY_MS, bounded,
     * and only while this node is still parent.
     */
    static final long ANCHOR_RETRY_MS = 5_000L;
    static final int  ANCHOR_RETRY_MAX = 24;          // ~2 min of quick retries
    private volatile int anchorRetries;

    private void scheduleAnchorRetry() {
        if (!cfg.nodeAddress.equalsIgnoreCase(currentParentAddr.get())) return;
        if (anchorRetries >= ANCHOR_RETRY_MAX) {
            LOG.warn("Lease anchor: quick retries exhausted; next attempt at the regular period");
            anchorRetries = 0;
            return;
        }
        anchorRetries++;
        scheduler.schedule(this::anchorLease, ANCHOR_RETRY_MS, TimeUnit.MILLISECONDS);
    }

    /** Lazily build the native PTB client (shared by claim, anchor and PoA). */
    private org.eclipse.om2m.sui.sdk.NativePtbBuilder nativePtb() throws java.io.IOException {
        org.eclipse.om2m.sui.sdk.NativePtbBuilder n = nativePtb;
        if (n == null) {
            synchronized (this) {
                n = nativePtb;
                if (n == null) {
                    org.eclipse.om2m.sui.sdk.NativePtbBuilder.Config nc =
                        new org.eclipse.om2m.sui.sdk.NativePtbBuilder.Config(
                            cfg.rpcUrl, cfg.packageId, cfg.packageOriginalId,
                            cfg.identityRegistryId, cfg.trustRegistryId,
                            cfg.policyRegistryId, cfg.auditTrailId,
                            cfg.suiClockId, cfg.gasBudget, cfg.minTrust);
                    n = new org.eclipse.om2m.sui.sdk.NativePtbBuilder(
                        nc, java.nio.file.Paths.get(cfg.keystorePath));
                    nativePtb = n;
                }
            }
        }
        return n;
    }

    /**
     * Make sure the chain advertises this node's PoA while it is the parent.
     *
     * <p>Previously the PoA was published only on the claim-success path, so a
     * node that was ALREADY parent at startup (the initial parent, or any parent
     * after a restart) never advertised itself and followers could not find it.
     * Now it runs whenever this node holds the parent role: on taking up duties
     * and on every lease anchor. It writes only when the on-chain value differs,
     * so in steady state it costs one read and no gas.
     */
    private void publishPoaIfNeeded() {
        String poa = cfg.parentPoa;
        if (poa == null || poa.isEmpty()) return;
        if (!cfg.nodeAddress.equalsIgnoreCase(currentParentAddr.get())) return;
        try {
            org.eclipse.om2m.sui.sdk.NativePtbBuilder n = nativePtb();
            if (poa.equals(n.fetchParentPoa(cfg.clusterId))) {
                writeLocalPoa(poa);
                return;
            }
            org.eclipse.om2m.sui.sdk.NativePtbBuilder.Result pr =
                n.setParentPoa(cfg.nodeAddress, cfg.clusterId, poa);
            if (pr.granted) {
                LOG.info("PoA published on-chain: " + poa + " digest=" + pr.digest
                         + " (" + pr.elapsedMs + " ms)");
                writeLocalPoa(poa);
            } else {
                LOG.warn("Failed to publish PoA on-chain (retry at next anchor): " + pr.error);
            }
        } catch (Throwable t) {
            LOG.warn("PoA publication error (retry at next anchor): " + t);
        }
    }

    /** Also write the PoA locally, for a co-located MN-CSE container if any. */
    private void writeLocalPoa(String poa) {
        try {
            String fp = cfg.poaFilePath;
            if (fp != null && !fp.isEmpty()) {
                java.nio.file.Path target = java.nio.file.Paths.get(fp);
                if (target.getParent() != null) java.nio.file.Files.createDirectories(target.getParent());
                java.nio.file.Files.write(target, poa.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
        } catch (Exception fe) {
            LOG.warn("Local PoA write failed: " + fe.getMessage());
        }
    }

    // === Watchdog ===
    private void watchdogTick() {
        long now = System.currentTimeMillis();
        long elapsed = now - lastHeartbeatMs.get();
        if (elapsed < cfg.heartbeatTimeoutMs) return;

        // We're a child node and the parent has gone quiet. Try to take
        // over. (If we are the parent, our own presence beat updates
        // lastHeartbeatMs implicitly via the broker -- the sender address
        // equals current_parent -- so we never reach this branch unless our own
        // MQTT broke too.)
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
        // Look before claiming. claim_parent aborts unless the on-chain lease
        // has expired and our trust clears the gate, and every abort is a
        // PAID failed transaction. Submitting on every 5 s tick while a 20 min
        // lease runs out would burn ~240 aborted claims per follower per
        // failover. All of the checks below are free reads.
        long ownScore = -1L, leaseExpires = Long.MAX_VALUE, gate = Long.MAX_VALUE;
        String chainParent = currentParentAddr.get();
        try {
            com.fasterxml.jackson.databind.JsonNode c =
                new org.eclipse.om2m.sui.sdk.SuiObjectFetcher(cfg.graphqlUrl, 5000)
                    .getMoveObjectJson(cfg.clusterId);
            chainParent  = c.path("current_parent").asText(chainParent);
            leaseExpires = Long.parseLong(c.path("lease_expires_ms").asText());
            gate         = Long.parseLong(c.path("trust_gate").asText());
            ownScore     = nativePtb().readTrustScore(cfg.nodeAddress);
        } catch (Throwable t) {
            LOG.warn("Pre-claim read failed (will retry next tick): " + t);
            return;
        }
        if (chainParent != null && !chainParent.equalsIgnoreCase(currentParentAddr.get())) {
            refreshCurrentParent();   // someone else already took over; follow them
            return;
        }
        ClaimGate g = gateClaim(now, leaseExpires, ownScore, gate, chainParent,
                                cfg.nodeAddress, claimBackoffUntilMs, claimInFlight.get());
        if (g != lastClaimGate) {     // log state changes, not every tick
            lastClaimGate = g;
            LOG.warn("Parent silence detected (" + elapsed + " ms); claim gate: " + g
                     + " (lease_expires_ms=" + leaseExpires + ", trust=" + ownScore
                     + ", gate=" + gate + ")");
        }
        if (g == ClaimGate.CLAIM) attemptClaim();
    }

    /** Result of the pre-claim check, mirroring failover::claim_parent. */
    enum ClaimGate { CLAIM, IN_FLIGHT, BACKOFF, ALREADY_PARENT, LEASE_VALID, TRUST_UNKNOWN, TRUST_BELOW_GATE }

    /** Claim only once chain time is this far past expiry (absorbs clock skew). */
    static final long LEASE_MARGIN_MS = 2_000L;
    static final long CLAIM_BACKOFF_MIN_MS = 15_000L;
    static final long CLAIM_BACKOFF_MAX_MS = 300_000L;

    /**
     * Pure claim decision, testable without a chain. It mirrors the on-chain
     * conditions that change over time (lease expiry, trust >= gate); identity
     * registration and role are fixed by the bootstrap.
     */
    static ClaimGate gateClaim(long nowMs, long leaseExpiresMs, long ownScore, long trustGate,
                               String chainParent, String self, long backoffUntilMs, boolean inFlight) {
        if (inFlight) return ClaimGate.IN_FLIGHT;
        if (nowMs < backoffUntilMs) return ClaimGate.BACKOFF;
        if (chainParent != null && chainParent.equalsIgnoreCase(self)) return ClaimGate.ALREADY_PARENT;
        if (nowMs < leaseExpiresMs + LEASE_MARGIN_MS) return ClaimGate.LEASE_VALID;
        if (ownScore < 0) return ClaimGate.TRUST_UNKNOWN;
        if (ownScore < trustGate) return ClaimGate.TRUST_BELOW_GATE;
        return ClaimGate.CLAIM;
    }

    /** Exponential backoff after consecutive rejected claims: 15 s doubling to 5 min. */
    static long claimBackoffMs(int consecutiveFailures) {
        long b = CLAIM_BACKOFF_MIN_MS;
        for (int i = 1; i < consecutiveFailures && b < CLAIM_BACKOFF_MAX_MS; i++) b *= 2;
        return Math.min(b, CLAIM_BACKOFF_MAX_MS);
    }

    private final java.util.concurrent.atomic.AtomicBoolean claimInFlight =
        new java.util.concurrent.atomic.AtomicBoolean(false);
    private volatile long claimBackoffUntilMs;
    private volatile int claimFailures;
    private volatile ClaimGate lastClaimGate;

    private void recordClaimFailure() {
        claimFailures++;
        claimBackoffUntilMs = System.currentTimeMillis() + claimBackoffMs(claimFailures);
    }

    /** The on-chain part of slide 10. Calls failover::claim_parent. */
        private void attemptClaim() {
        if (!claimInFlight.compareAndSet(false, true)) return;   // one claim at a time
        // Submit off-thread so watchdog stays responsive
        scheduler.submit(() -> {
            try {
                org.eclipse.om2m.sui.sdk.NativePtbBuilder n = nativePtb();
                org.eclipse.om2m.sui.sdk.NativePtbBuilder.Result r =
                    n.claimParent(cfg.nodeAddress, cfg.clusterId);
                if (r.granted) {
                    LOG.info("CLAIM ACCEPTED — we are now parent of cluster " + cfg.clusterId
                             + " digest=" + r.digest + " (" + r.elapsedMs + " ms)");
                    claimFailures = 0;
                    currentParentAddr.set(cfg.nodeAddress);
                    // PoA publication now happens in startParentDuties ->
                    // anchorLease -> publishPoaIfNeeded, which covers the claim
                    // path AND a node that is already parent at startup.
                    String poa = cfg.parentPoa;
                    if (poa != null && !poa.isEmpty()) {
                        // Trigger role-switch to IN-CSE
                        invokeRoleSwitch("in", null);
                    }
                    startParentDuties();
                } else if (isGasExhaustion(r.error)) {
                    // FM5: funding failure, not an ordinary rejection. Surface it.
                    surfaceGasExhaustion(r.error);
                    recordClaimFailure();
                    refreshCurrentParent();
                } else {
                    LOG.info("Claim rejected on-chain: " + r.error + " (digest=" + r.digest + ")");
                    recordClaimFailure();
                    refreshCurrentParent();
                }
            } catch (Throwable e) {
                recordClaimFailure();
                if (isGasExhaustion(e.getMessage())) {
                    surfaceGasExhaustion(e.getMessage());
                } else {
                    LOG.warn("Claim submission failed: " + e);
                }
            } finally {
                claimInFlight.set(false);
            }
        });
    }

    /** Read the cluster object and cache current_parent. */
    private void refreshCurrentParent() {
        // Direct GraphQL fetch — avoid blocking the OSGi Activator on a CLI fork.
        // HTTP errors, GraphQL errors and a missing object all throw (logged
        // below as a read failure); they are never read as "no parent".
        try {
            com.fasterxml.jackson.databind.JsonNode fields =
                new org.eclipse.om2m.sui.sdk.SuiObjectFetcher(cfg.graphqlUrl, 5000)
                    .getMoveObjectJson(cfg.clusterId);
            String parent = fields.path("current_parent").asText("");
            if (!parent.isEmpty()) {
                String previous = currentParentAddr.get();
                currentParentAddr.set(parent);
                // Detect parent change. If it's not us, read the new PoA from
                // chain and persist it for follower bootstrapping.
                boolean changed = (previous == null) || previous.isEmpty()
                        || !previous.equalsIgnoreCase(parent);
                if (changed) LOG.info("Cluster current parent = " + parent);
                if (shouldTakeUpParentDuties(parent, cfg.nodeAddress, parentDutiesRunning())) {
                    LOG.warn("Chain names this node parent but parent duties were not running;"
                             + " taking them up now (lease anchor + PoA)");
                    startParentDuties();
                }
                if (changed && !parent.equalsIgnoreCase(cfg.nodeAddress)) {
                    // FM3: the chain now names someone else as parent. If we were
                    // running parent duties, tear them down before switching role.
                    stopParentDuties();  // FM3
                    onParentChanged(parent);
                } else if (!changed && !parent.equalsIgnoreCase(cfg.nodeAddress)) {
                    followParentPoa();
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
                                    cfg.rpcUrl, cfg.packageId, cfg.packageOriginalId,
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
                lastFollowedPoa = poa;
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

    /** The PoA this follower last persisted (null until the first one). */
    private volatile String lastFollowedPoa;

    /**
     * Followers re-check the advertised PoA on every chain sync. The on-chain
     * PoA is not bound to the parent that set it, so right after a takeover it
     * still holds the DEPOSED parent's URL until the new parent publishes its
     * own (seconds later). onParentChanged read it in that window on
     * 2026-11-10 and persisted the old parent's PoA with nothing to correct
     * it. Re-reading on each sync converges within one period. Cheap: one
     * GraphQL read, and a write only when the value changed.
     */
    private void followParentPoa() {
        if (cfg.poaFilePath == null || cfg.poaFilePath.isEmpty()) return;
        try {
            String poa = nativePtb().fetchParentPoa(cfg.clusterId);
            if (!poaNeedsUpdate(poa, lastFollowedPoa)) return;
            writeLocalPoa(poa);
            LOG.info("Parent PoA changed on-chain: " + lastFollowedPoa + " -> " + poa + " (written to " + cfg.poaFilePath + ")");
            lastFollowedPoa = poa;
            invokeRoleSwitch("mn", poa);
        } catch (Throwable t) {
            LOG.warn("PoA follow read failed (retry next sync): " + t);
        }
    }

    /** Pure: persist a newly read PoA only if it is non-empty and differs. */
    static boolean poaNeedsUpdate(String chainPoa, String lastWritten) {
        return chainPoa != null && !chainPoa.isEmpty() && !chainPoa.equals(lastWritten);
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
