package org.eclipse.om2m.sui.trust;

import org.eclipse.paho.client.mqttv3.IMqttDeliveryToken;
import org.eclipse.paho.client.mqttv3.MqttCallback;
import org.eclipse.paho.client.mqttv3.MqttClient;
import org.eclipse.paho.client.mqttv3.MqttConnectOptions;
import org.eclipse.paho.client.mqttv3.MqttException;
import org.eclipse.paho.client.mqttv3.MqttMessage;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;

import java.util.Collection;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * The decentralised peer-attestation layer.
 *
 * <p><b>Why this design.</b> Peer attestation needs every node's view of every
 * other node to be visible to all nodes, so the ≥-threshold agreement rule can
 * be evaluated independently by each node. The three obvious places to put that
 * shared view each have a fatal flaw for our setting:
 * <ul>
 *   <li><i>Aggregate on the parent.</i> Single point of failure — and the
 *       parent failing is exactly when trust scoring matters most.</li>
 *   <li><i>Anchor every observation on-chain.</i> One Sui transaction per node
 *       per second is absurd gas; the chain is for decisions, not telemetry.</li>
 *   <li><i>Gossip over MQTT.</i> The broker is already in the testbed (the
 *       failover heartbeats use it), it is free, and every node hears every
 *       observation — so each node reconstructs the same global view and can
 *       apply the agreement rule on its own.</li>
 * </ul>
 * We use MQTT gossip. Each node publishes its observations to
 * {@code om2m/trust/obs/<clusterId>}; every node subscribes to the same topic
 * and keeps the latest observation from each (observer, target) pair.
 *
 * <p>The freshness of an observer's gossip also doubles as a liveness signal:
 * the engine's deterministic-submitter rule treats a node as "alive" iff its
 * most recent gossip is within {@code peerLivenessMs}. That is how submission
 * authority migrates automatically when a node dies — no extra mechanism.
 */
final class TrustGossip implements MqttCallback {

    private static final Slf4jStyleLog LOG = Slf4jStyleLog.getLogger(TrustGossip.class);
    private static final String TOPIC_PREFIX = "om2m/trust/obs/";

    private final String brokerUrl;
    private final String clusterId;
    private final String selfAddr;
    private final long   peerLivenessMs;
    private final org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters signKey;
    private final String signPubB64;
    private volatile BehaviourObserver observer;

    private MqttClient mqtt;
    private final String topic;

    // (observerAddr -> (targetAddr -> latest observation))
    private final Map<String, Map<String, NodeObservation>> latest = new ConcurrentHashMap<>();
    // observerAddr -> last time we heard anything from them
    private final Map<String, Long> lastSeen = new ConcurrentHashMap<>();

    TrustGossip(String brokerUrl, String clusterId, String selfAddr, long peerLivenessMs,
                String keystorePath) {
        this.brokerUrl = brokerUrl;
        this.clusterId = clusterId;
        this.selfAddr = selfAddr;
        this.peerLivenessMs = peerLivenessMs;
        this.topic = TOPIC_PREFIX + clusterId;
        org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters k = null;
        String pub = null;
        try {
            if (keystorePath != null) {
                com.fasterxml.jackson.databind.JsonNode arr =
                    new com.fasterxml.jackson.databind.ObjectMapper()
                        .readTree(new java.io.File(keystorePath));
                if (arr.isArray() && arr.size() > 0) {
                    k = GossipSig.loadPrivateKey(arr.get(0).asText());
                    pub = GossipSig.publicKeyB64(k);
                    String derived = GossipSig.addressOf(pub);
                    boolean mismatch = derived.equalsIgnoreCase(selfAddr) == false;
                    if (mismatch) {
                        LOG.warn("[trust] sign key {} != selfAddr {}; signing disabled", derived, selfAddr);
                        k = null; pub = null;
                    }
                }
            }
        } catch (Exception e) {
            LOG.warn("[trust] sign key load failed: {}; signing disabled", e.getMessage());
            k = null; pub = null;
        }
        this.signKey = k;
        this.signPubB64 = pub;
        LOG.info("[trust] gossip signing {}", (k != null ? "ENABLED" : "disabled"));
    }

    void attachObserver(BehaviourObserver o) { this.observer = o; }

    void start() {
        try {
            String clientId = "sui-trust-" + selfAddr + "-" + UUID.randomUUID();
            mqtt = new MqttClient(brokerUrl, clientId, new MemoryPersistence());
            MqttConnectOptions opts = new MqttConnectOptions();
            opts.setCleanSession(true);
            opts.setAutomaticReconnect(true);
            opts.setKeepAliveInterval(30);
            mqtt.setCallback(this);
            mqtt.connect(opts);
            mqtt.subscribe(topic);
            // Count ourselves alive from the start.
            lastSeen.put(selfAddr, System.currentTimeMillis());
            LOG.info("[trust] gossip connected to {} topic={}", brokerUrl, topic);
        } catch (MqttException e) {
            LOG.error("[trust] gossip MQTT connect failed", e);
        }
    }

    void stop() {
        if (mqtt != null) {
            try { mqtt.disconnect(); } catch (MqttException ignored) {}
        }
    }

    /** Publish a batch of this node's observations (one per observed target). */
    void publish(Collection<NodeObservation> observations) {
        if (mqtt == null || !mqtt.isConnected()) return;
        for (NodeObservation obs : observations) {
            try {
                if (signKey != null) {
                    obs.sigB64 = GossipSig.sign(signKey, obs.unsignedBytes());
                    obs.pubKeyB64 = signPubB64;
                }
                MqttMessage m = new MqttMessage(obs.encodeSigned().getBytes());
                m.setQos(0); // telemetry: lossy is fine, next tick refreshes
                mqtt.publish(topic, m);
            } catch (MqttException e) {
                LOG.debug("[trust] gossip publish failed: {}", e.getMessage());
            }
        }
        // We just demonstrated our own liveness.
        lastSeen.put(selfAddr, System.currentTimeMillis());
    }

    // SY5: replay decision as a pure, testable predicate. An incoming
    // observation is a replay/stale if we already hold one for this
    // (observer,target) whose producedAtMs is >= the incoming one (i.e. the
    // incoming is not STRICTLY newer). Extracted so the monotonic-ingest
    // invariant can be unit-tested directly (see TrustGossipReplayTest).
    static boolean isReplay(NodeObservation prev, NodeObservation incoming) {
        return prev != null && incoming.producedAtMs <= prev.producedAtMs;
    }

    @Override
    public void messageArrived(String t, MqttMessage message) {
        NodeObservation obs = NodeObservation.decode(new String(message.getPayload()));
        if (obs == null) return;
        // Ignore our own echoes — we already hold our own observations locally.
        if (obs.observerAddr.equalsIgnoreCase(selfAddr)) return;

        // Authentication: verify the message was really signed by the node
        // whose address it claims as observerAddr.
        boolean signed = (obs.sigB64 != null && obs.pubKeyB64 != null);
        if (signed) {
            boolean sigOk = GossipSig.verify(obs.pubKeyB64, obs.unsignedBytes(), obs.sigB64);
            String derived = sigOk ? GossipSig.addressOf(obs.pubKeyB64) : null;
            boolean addrOk = (derived != null) && derived.equalsIgnoreCase(obs.observerAddr);
            if (sigOk == false || addrOk == false) {
                BehaviourObserver o = observer;
                if (o != null) o.setImpersonationFlag(obs.observerAddr, true);
                LOG.warn("[trust] gossip auth FAILED for claimed observer {} (sigOk={} addrOk={}); dropping",
                         obs.observerAddr, sigOk, addrOk);
                return;
            }
            BehaviourObserver o = observer;
            if (o != null) o.setImpersonationFlag(obs.observerAddr, false);
            if (hasGarbageValues(obs)) {
                if (o != null) o.setGarbageFlag(obs.observerAddr, true);
                LOG.warn("[trust] gossip from {} out-of-range; garbage flag raised", obs.observerAddr);
                return;
            } else {
                if (o != null) o.setGarbageFlag(obs.observerAddr, false);
            }
        }

        // SY5: replay hardening. Reject a (signed) observation whose producedAtMs
        // is not strictly newer than the one we already hold for this
        // (observer,target). Without this, an attacker could replay an OLDER
        // captured-and-signed observation within the freshness window and
        // override a newer one (out-of-order replay). Monotonic producedAtMs
        // per (observer,target) makes ingest replay-safe, not just
        // last-write-wins.
        Map<String, NodeObservation> perObserver =
            latest.computeIfAbsent(obs.observerAddr, a -> new ConcurrentHashMap<>());
        NodeObservation prev = perObserver.get(obs.targetAddr);
        if (isReplay(prev, obs)) {
            LOG.warn("[trust] SY5 replay rejected: stale/duplicate obs from {} about {}"
                    + " (producedAtMs {} <= stored {})",
                    obs.observerAddr, obs.targetAddr, obs.producedAtMs, prev.producedAtMs);
            return;
        }
        perObserver.put(obs.targetAddr, obs);
        lastSeen.put(obs.observerAddr, System.currentTimeMillis());
    }

    @Override public void connectionLost(Throwable cause) {
        LOG.warn("[trust] gossip MQTT connection lost: {}",
                 cause == null ? "?" : cause.getMessage());
    }
    @Override public void deliveryComplete(IMqttDeliveryToken token) { /* unused */ }

    // ===================================================================
    // Reads used by the engine.
    // ===================================================================

    /** All remote observations of {@code target}, fresh ones only. */
    java.util.List<NodeObservation> remoteObservationsOf(String target, long nowMs) {
        java.util.List<NodeObservation> out = new java.util.ArrayList<>();
        for (Map.Entry<String, Map<String, NodeObservation>> e : latest.entrySet()) {
            String observer = e.getKey();
            if (!isAlive(observer, nowMs)) continue;            // stale source
            NodeObservation obs = e.getValue().get(target);
            if (obs == null) continue;
            if (nowMs - obs.producedAtMs > peerLivenessMs) continue; // stale obs
            out.add(obs);
        }
        return out;
    }

    /** Is this observer's gossip recent enough to consider the node alive? */
    boolean isAlive(String addr, long nowMs) {
        if (addr.equalsIgnoreCase(selfAddr)) return true; // we know we're alive
        Long t = lastSeen.get(addr);
        return t != null && (nowMs - t) <= peerLivenessMs;
    }

    /** Distinct addresses currently considered alive (peers + self). */
    java.util.Set<String> aliveNodes(long nowMs) {
        java.util.Set<String> out = new java.util.HashSet<>();
        out.add(selfAddr);
        for (String a : lastSeen.keySet()) {
            if (isAlive(a, nowMs)) out.add(a);
        }
        return out;
    }

    /** True if any health value is outside [0,1] or non-finite. */
    private static boolean hasGarbageValues(NodeObservation o) {
        double[] vals = {
            o.heartbeatHealth, o.malformedHealth, o.rateHealth, o.clockHealth,
            o.deniedBurstHealth, o.ptbAbortHealth, o.historicalHealth, o.inactiveHealth
        };
        for (double v : vals) {
            if (Double.isNaN(v) || Double.isInfinite(v) || v < 0.0 || v > 1.0) return true;
        }
        return false;
    }

}
