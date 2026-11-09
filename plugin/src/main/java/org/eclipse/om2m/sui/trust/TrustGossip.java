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
 * {@code om2m/trust/obs/<clusterId>/<observerAddr>}; every node subscribes to {@code .../<clusterId>/+}
 * and keeps the latest observation from each (observer, target) pair.
 *
 * <p>The freshness of an observer's gossip also doubles as a liveness signal:
 * the engine's deterministic-submitter rule treats a node as "alive" iff it is
 * a registered member and its most recent gossip is within
 * {@code peerLivenessMs}. That is how submission authority migrates
 * automatically when a node dies — no extra mechanism.
 *
 * <p><b>Admission rules applied to every inbound observation</b> (all of these
 * must pass, in order):
 * <ol>
 *   <li>B1 — it must be <i>signed</i>. An unsigned observation is rejected,
 *       not merely exempted from the signature check.</li>
 *   <li>The signature must verify, and the address derived from the shipped
 *       public key must equal the claimed {@code observerAddr}. B2: a failure
 *       here is charged to the <i>derived</i> (real) signer, never to the
 *       claimed address, which is the victim of the forgery.</li>
 *   <li>B10 — the observer must appear in the on-chain identity registry.
 *       A self-minted keypair is self-consistent but not a cluster member.</li>
 *   <li>B4 — the observation must not be a self-observation
 *       ({@code observer == target}); nodes do not grade themselves.</li>
 *   <li>Health values must be in range, and B6 — the ordinal
 *       {@code (epoch, producedAtMs)} must be strictly newer than what we hold
 *       for this (observer, target).</li>
 * </ol>
 */
final class TrustGossip implements MqttCallback {

    private static final Slf4jStyleLog LOG = Slf4jStyleLog.getLogger(TrustGossip.class);
    private static final String TOPIC_PREFIX = "om2m/trust/obs/";

    private final String brokerUrl;
    private final String clusterId;
    private final String selfAddr;
    private final long   peerLivenessMs;
    private final MemberRegistry members;
    private final org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters signKey;
    private final String signPubB64;
    private volatile BehaviourObserver observer;

    private MqttClient mqtt;
    // Per-origin topics: each node PUBLISHES on .../<clusterId>/<selfAddr>
    // and SUBSCRIBES to .../<clusterId>/+. The broker mesh bridges only a
    // node's OWN subtree outward, so a message is forwarded exactly once and
    // never re-forwarded. A single shared topic made the three-broker full mesh
    // a cycle: messages were re-bridged forever (MQTT has no TTL), measured
    // on 2026-11-10 as ~213k messages per 8 s carrying only 110 distinct
    // payloads. See deploy/mosquitto/gen-mesh-conf.sh.
    private final String subscribeTopic;
    private final String publishTopic;

    // (observerAddr -> (targetAddr -> latest observation))
    private final Map<String, Map<String, NodeObservation>> latest = new ConcurrentHashMap<>();
    // observerAddr -> last time we heard anything from them
    private final Map<String, Long> lastSeen = new ConcurrentHashMap<>();

    TrustGossip(String brokerUrl, String clusterId, String selfAddr, long peerLivenessMs,
                String keystorePath, MemberRegistry members) {
        this.brokerUrl = brokerUrl;
        this.clusterId = clusterId;
        this.selfAddr = selfAddr;
        this.peerLivenessMs = peerLivenessMs;
        this.members = members;
        this.subscribeTopic = TOPIC_PREFIX + clusterId + "/+";
        this.publishTopic   = TOPIC_PREFIX + clusterId + "/" + selfAddr.toLowerCase();
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
        if (k == null) {
            // B1 makes unsigned gossip unacceptable on the receive side, so a
            // node that cannot sign is mute as far as its peers are concerned.
            LOG.error("[trust] signing disabled — peers will REJECT this node's gossip (B1)."
                    + " Check sui.keystore.path and that its first entry matches sui.node.address.");
        }
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
            mqtt.subscribe(subscribeTopic);
            // Count ourselves alive from the start.
            lastSeen.put(selfAddr, System.currentTimeMillis());
            LOG.info("[trust] gossip connected to {} sub={} pub={}", brokerUrl, subscribeTopic, publishTopic);
        } catch (MqttException e) {
            LOG.error("[trust] gossip MQTT connect failed", e);
        }
    }

    void stop() {
        if (mqtt != null) {
            try { mqtt.disconnect(); } catch (MqttException ignored) {}
        }
    }

    /**
     * Publish a batch of this node's observations (one per observed target).
     *
     * <p>B4: self-observations are not published. A node's own opinion of itself
     * must never reach a third party's aggregate — it is unattested input that
     * the node fully controls, so publishing it let a node inflate (or, by
     * omission, deflate) the score peers computed for it.
     */
    void publish(Collection<NodeObservation> observations) {
        if (mqtt == null || !mqtt.isConnected()) return;
        for (NodeObservation obs : observations) {
            // B4 (publish path): never gossip observer == target.
            if (obs.observerAddr.equalsIgnoreCase(obs.targetAddr)) continue;
            try {
                if (signKey != null) {
                    obs.sigB64 = GossipSig.sign(signKey, obs.unsignedBytes());
                    obs.pubKeyB64 = signPubB64;
                }
                MqttMessage m = new MqttMessage(obs.encodeSigned().getBytes());
                m.setQos(0); // telemetry: lossy is fine, next tick refreshes
                mqtt.publish(publishTopic, m);
            } catch (MqttException e) {
                LOG.debug("[trust] gossip publish failed: {}", e.getMessage());
            }
        }
        // We just demonstrated our own liveness.
        lastSeen.put(selfAddr, System.currentTimeMillis());
    }

    /**
     * SY5 / B6: replay decision as a pure, testable predicate.
     *
     * <p>The ordinal is the lexicographic pair {@code (epoch, producedAtMs)}:
     * <ul>
     *   <li>a strictly higher {@code epoch} is always accepted — a bumped epoch
     *       means the observer restarted, and its wall clock may legitimately
     *       have moved backwards across that restart (NTP correction, or an
     *       RTC-less Pi booting before it has network time). Under the old
     *       timestamp-only rule such a node was rejected as a replayer
     *       <i>permanently</i>, until its clock caught back up;</li>
     *   <li>a strictly lower {@code epoch} is a stale/replayed pre-restart
     *       observation and is rejected;</li>
     *   <li>within the same epoch the original rule stands: {@code producedAtMs}
     *       must be strictly greater, so a captured-and-signed older
     *       observation cannot override a newer one.</li>
     * </ul>
     * Extracted so the monotonic-ingest invariant can be unit-tested directly
     * (see TrustGossipReplayTest).
     */
    static boolean isReplay(NodeObservation prev, NodeObservation incoming) {
        if (prev == null) return false;
        if (incoming.epoch > prev.epoch) return false;  // observer restarted
        if (incoming.epoch < prev.epoch) return true;   // pre-restart leftover
        return incoming.producedAtMs <= prev.producedAtMs;
    }

    @Override
    public void messageArrived(String t, MqttMessage message) {
        // Paho's CommsCallback.run() wraps this callback in `catch (Throwable)`
        // and responds by tearing the connection down, so anything thrown from
        // here kills the MQTT link; with automatic reconnect enabled that
        // degenerates into a reconnect loop and the node goes gossip-deaf. That
        // matters because the B10 membership gate below reaches off-node (see
        // IdentityRegistryMembers, which performs an RPC), so "isMember cannot
        // throw" is not a safe assumption — and a remote peer chooses when we
        // consult it. MemberRegistry's contract is to fail CLOSED, so contain
        // the failure here: a failed admission must cost us one observation,
        // never the connection.
        try {
            handleObservation(message);
        } catch (RuntimeException e) {
            LOG.warn("[trust] dropping gossip message after unexpected error ({}): {}",
                     e.getClass().getSimpleName(), String.valueOf(e.getMessage()));
        }
    }

    private void handleObservation(MqttMessage message) {
        NodeObservation obs = NodeObservation.decode(new String(message.getPayload()));
        if (obs == null) return;
        // Ignore our own echoes — we already hold our own observations locally.
        if (obs.observerAddr.equalsIgnoreCase(selfAddr)) return;

        BehaviourObserver o = observer;

        // B1: an observation with no signature/pubkey is REJECTED. Previously
        // the whole authentication block sat inside `if (signed) {...}`, so an
        // attacker only had to strip the two signature fields to skip every
        // check and still be ingested as a valid observer.
        if (obs.sigB64 == null || obs.pubKeyB64 == null) {
            LOG.warn("[trust] B1 unsigned gossip from claimed observer {} about {}; dropping",
                     obs.observerAddr, obs.targetAddr);
            return;
        }

        // Authentication: verify the message was really signed by the node
        // whose address it claims as observerAddr.
        boolean sigOk = GossipSig.verify(obs.pubKeyB64, obs.unsignedBytes(), obs.sigB64);
        String derived = sigOk ? GossipSig.addressOf(obs.pubKeyB64) : null;
        boolean addrOk = (derived != null) && derived.equalsIgnoreCase(obs.observerAddr);
        if (sigOk == false || addrOk == false) {
            // B2: charge the forgery to the address the signature actually
            // belongs to. The old code raised the flag on obs.observerAddr —
            // the CLAIMED address — which let anyone drive an honest node's
            // score down just by signing junk in that node's name. If the
            // signature does not verify at all we cannot attribute it to
            // anybody, so nobody is penalised.
            //
            // The derived address is additionally required to be a cluster
            // member before we record anything against it: a non-member's trust
            // score is inert anyway (B10 drops its gossip outright), and
            // flagging it would let an attacker spawn an unbounded number of
            // tracked peers in BehaviourObserver just by signing with fresh
            // throwaway keys.
            if (derived != null && o != null && members.isMember(derived)) {
                o.setGarbageFlag(derived, true);
            }
            LOG.warn("[trust] gossip auth FAILED: claimed observer {} (sigOk={} addrOk={}),"
                    + " real signer {}; dropping{}",
                     obs.observerAddr, sigOk, addrOk,
                     (derived == null ? "<unattributable>" : derived),
                     (derived == null ? " (no one penalised)" : " and flagging the real signer"));
            return;
        }

        // B10: a valid signature only proves key possession. Require actual
        // cluster membership (on-chain identity registry) before this observer
        // can influence anything — otherwise an attacker mints keypairs to
        // inflate the observer count n (defeating the B3 Byzantine bound) and
        // to capture the lowest-address submitter election.
        if (!members.isMember(obs.observerAddr)) {
            LOG.warn("[trust] B10 gossip from unregistered observer {}; dropping",
                     obs.observerAddr);
            return;
        }

        // B4 (read path): an observer's view of itself is not peer attestation.
        if (obs.observerAddr.equalsIgnoreCase(obs.targetAddr)) {
            LOG.debug("[trust] B4 self-observation from {} dropped", obs.observerAddr);
            return;
        }

        if (hasGarbageValues(obs)) {
            if (o != null) o.setGarbageFlag(obs.observerAddr, true);
            LOG.warn("[trust] gossip from {} out-of-range; garbage flag raised", obs.observerAddr);
            return;
        } else {
            if (o != null) o.setGarbageFlag(obs.observerAddr, false);
        }

        // SY5/B6: replay hardening. Reject an observation whose
        // (epoch, producedAtMs) ordinal is not strictly newer than the one we
        // already hold for this (observer, target). Without this, an attacker
        // could replay an OLDER captured-and-signed observation within the
        // freshness window and override a newer one (out-of-order replay).
        Map<String, NodeObservation> perObserver =
            latest.computeIfAbsent(obs.observerAddr, a -> new ConcurrentHashMap<>());
        NodeObservation prev = perObserver.get(obs.targetAddr);
        if (isReplay(prev, obs)) {
            LOG.warn("[trust] SY5 replay rejected: stale/duplicate obs from {} about {}"
                    + " (epoch/ts {}/{} <= stored {}/{})",
                    obs.observerAddr, obs.targetAddr, obs.epoch, obs.producedAtMs,
                    prev.epoch, prev.producedAtMs);
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

    /**
     * All remote observations of {@code target}, fresh ones only.
     *
     * <p>B4: entries where the observer IS the target are skipped. Including
     * them meant a node's self-assessment was mixed into the aggregate every
     * other node computed about it.
     */
    java.util.List<NodeObservation> remoteObservationsOf(String target, long nowMs) {
        java.util.List<NodeObservation> out = new java.util.ArrayList<>();
        for (Map.Entry<String, Map<String, NodeObservation>> e : latest.entrySet()) {
            String observer = e.getKey();
            if (observer.equalsIgnoreCase(target)) continue;     // B4: no self-observations
            if (!isAlive(observer, nowMs)) continue;             // stale source
            NodeObservation obs = e.getValue().get(target);
            if (obs == null) continue;
            if (obs.observerAddr.equalsIgnoreCase(obs.targetAddr)) continue; // B4 (defensive)
            if (nowMs - obs.producedAtMs > peerLivenessMs) continue; // stale obs
            out.add(obs);
        }
        return out;
    }

    /**
     * Is this observer a registered member whose gossip is recent enough to
     * consider the node alive? B10: membership is part of liveness — an
     * unregistered address is never "alive" for submitter-election or
     * peer-count purposes.
     */
    boolean isAlive(String addr, long nowMs) {
        if (addr.equalsIgnoreCase(selfAddr)) return true; // we know we're alive
        if (!members.isMember(addr)) return false;        // B10
        Long t = lastSeen.get(addr);
        return t != null && (nowMs - t) <= peerLivenessMs;
    }

    /** Distinct registered addresses currently considered alive (peers + self). */
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
            o.deniedBurstHealth, o.historicalHealth, o.inactiveHealth
        };
        for (double v : vals) {
            if (Double.isNaN(v) || Double.isInfinite(v) || v < 0.0 || v > 1.0) return true;
        }
        return false;
    }

}
