package org.eclipse.om2m.sui.trust;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;

import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters;
import org.eclipse.paho.client.mqttv3.MqttMessage;
import org.junit.Test;

/**
 * GO9 invariant: <b>only middleware nodes registered in the identity registry
 * are admitted as observers.</b>
 *
 * <p><b>Why this invariant exists (B10).</b> Gossip authentication
 * ({@link GossipSig}) proves only that the sender holds the private key for the
 * address it claims — it is <i>self-certifying</i>. Anyone can mint a fresh
 * Ed25519 keypair, derive its Sui address, and sign a perfectly valid
 * observation with it. Without an authorisation half, such a stranger is
 * ingested as a brand-new "alive observer", which (a) stuffs the peer-agreement
 * denominator {@code n} and defeats the Byzantine bound in
 * {@code TrustScoringEngine.aggregateAndScore}, and (b) lets the attacker win
 * the lexicographically-lowest-address submitter election at will by grinding
 * keys. {@link MemberRegistry} is that missing authorisation half: an observer
 * is admitted only if it appears in the on-chain
 * {@code om2m_access::identity} registry, which only the IN-CSE's
 * {@code AdminCap} can write.
 *
 * <p><b>Why these tests drive the real receive path.</b> Asserting
 * {@code isAlive("0xstranger", now) == false} on its own proves nothing: that
 * address has no {@code lastSeen} entry, so the answer would be {@code false}
 * even with the membership gate deleted. Every case below therefore pushes a
 * genuinely well-formed observation — correctly signed, address-consistent,
 * fresh, in-range, non-replayed, non-self — through
 * {@link TrustGossip#messageArrived} via a directly-constructed
 * {@link MqttMessage} (no broker, no network, no filesystem). The positive
 * control in {@link #sameObservationFromRegisteredObserverIsAdmitted()} replays
 * the <i>byte-identical</i> payload with the registry answering {@code true} and
 * shows it <i>is</i> admitted, which is what pins the rejection in the negative
 * case on the membership check and nothing else.
 */
public class TrustGossipMembershipTest {

    private static final String SELF_ADDR = "0xself0000000000000000000000000000"
                                          + "000000000000000000000000000000";
    private static final String TARGET    = "0xtarget000000000000000000000000000"
                                          + "00000000000000000000000000000";
    private static final String CLUSTER   = "testcluster";
    private static final String TOPIC     = "om2m/trust/obs/" + CLUSTER;
    /** Generous window: these tests stamp liveness off the real wall clock. */
    private static final long LIVENESS_MS = 10 * 60 * 1000L;

    // =================================================================
    // Test doubles.
    // =================================================================

    /**
     * A {@link MemberRegistry} under the test's control. Membership is a plain
     * mutable set so revocation can be simulated mid-test; {@code answer} can be
     * pinned to a constant to model a registry that cannot establish membership
     * at all (the unconfigured / RPC-down case, which the contract requires to
     * fail closed), and {@code boom} models an implementation that violates the
     * contract by throwing instead.
     */
    private static final class FakeMembers implements MemberRegistry {
        private final List<String> registered = new ArrayList<>();
        private final AtomicInteger calls = new AtomicInteger();
        private Boolean pinned;          // non-null: always answer this
        private RuntimeException boom;   // non-null: throw instead of answering

        static FakeMembers with(String... addrs) {
            FakeMembers m = new FakeMembers();
            for (String a : addrs) m.register(a);
            return m;
        }
        static FakeMembers alwaysFalse() { FakeMembers m = new FakeMembers(); m.pinned = Boolean.FALSE; return m; }
        static FakeMembers throwing() {
            FakeMembers m = new FakeMembers();
            m.boom = new IllegalStateException("identity registry RPC unreachable");
            return m;
        }

        void register(String addr) { registered.add(addr.toLowerCase()); }
        void revoke(String addr)   { registered.remove(addr.toLowerCase()); }
        int calls()                { return calls.get(); }

        @Override
        public boolean isMember(String addr) {
            calls.incrementAndGet();
            if (boom != null) throw boom;
            if (pinned != null) return pinned.booleanValue();
            return addr != null && registered.contains(addr.toLowerCase());
        }
    }

    /** A freshly minted node identity: keypair plus the Sui address it derives. */
    private static final class Node {
        final Ed25519PrivateKeyParameters priv;
        final String pubB64;
        final String addr;
        Node() {
            byte[] seed = new byte[32];
            new SecureRandom().nextBytes(seed);
            this.priv   = new Ed25519PrivateKeyParameters(seed, 0);
            this.pubB64 = GossipSig.publicKeyB64(priv);
            this.addr   = GossipSig.addressOf(pubB64);
        }
    }

    // =================================================================
    // Helpers.
    // =================================================================

    private static TrustGossip gossip(MemberRegistry members) {
        // keystorePath == null: this node cannot sign, which is irrelevant here
        // — every test signs its payload itself. Nothing touches the network:
        // the broker URL is never dialled because start() is never called.
        return new TrustGossip("tcp://127.0.0.1:1", CLUSTER, SELF_ADDR,
                               LIVENESS_MS, null, members);
    }

    /**
     * A correctly signed, fresh, in-range, non-self observation by {@code by} of
     * {@code target}, serialised to the v2 signed wire form. The signature is
     * over the exact bytes the receiver verifies ({@code unsignedBytes()}), so
     * the only admission rule still in play when this payload is delivered is
     * the membership gate.
     */
    private static byte[] signedWire(Node by, String target, long producedAtMs) {
        NodeObservation obs = new NodeObservation(
            by.addr, target, 1L, producedAtMs,
            1.0d, 1.0d, 1.0d, 1.0d,
            1.0d, 1.0d, 1.0d,
            false);
        obs.sigB64    = GossipSig.sign(by.priv, obs.unsignedBytes());
        obs.pubKeyB64 = by.pubB64;
        return obs.encodeSigned().getBytes(java.nio.charset.StandardCharsets.UTF_8);
    }

    /** Sanity: the payload really is cryptographically sound before we ship it. */
    private static void assertPayloadIsWellFormed(Node by, byte[] wire) {
        NodeObservation back = NodeObservation.decode(
            new String(wire, java.nio.charset.StandardCharsets.UTF_8));
        assertTrue("fixture payload must decode as v2", back != null);
        assertTrue("fixture payload must carry a signature and public key",
                back.sigB64 != null && back.pubKeyB64 != null);
        assertTrue("fixture signature must verify — otherwise a rejection could be"
                + " blamed on the signature rather than on membership",
                GossipSig.verify(back.pubKeyB64, back.unsignedBytes(), back.sigB64));
        assertEquals("fixture address must derive from the shipped public key",
                by.addr, GossipSig.addressOf(back.pubKeyB64));
    }

    private static boolean observedBy(List<NodeObservation> obs, String observerAddr) {
        for (NodeObservation o : obs) {
            if (o.observerAddr.equalsIgnoreCase(observerAddr)) return true;
        }
        return false;
    }

    // =================================================================
    // GO9 — the invariant itself.
    // =================================================================

    @Test
    public void unregisteredObserverGossipIsDropped() {
        Node stranger = new Node();
        long now = System.currentTimeMillis();
        byte[] wire = signedWire(stranger, TARGET, now);
        assertPayloadIsWellFormed(stranger, wire);

        // Registry knows the target but has never heard of the stranger.
        FakeMembers members = FakeMembers.with(TARGET);
        TrustGossip g = gossip(members);

        g.messageArrived(TOPIC, new MqttMessage(wire));

        assertTrue("the membership gate must actually have been consulted",
                members.calls() > 0);
        assertFalse("GO9: an observation from an address absent from the identity"
                + " registry must not reach the aggregate, however well it is signed",
                observedBy(g.remoteObservationsOf(TARGET, now), stranger.addr));
        assertEquals("GO9: no observation of the target may be admitted from an"
                + " unregistered observer",
                0, g.remoteObservationsOf(TARGET, now).size());
        assertFalse("GO9: an unregistered observer must never count as alive —"
                + " liveness is gated on membership, not merely on freshness",
                g.isAlive(stranger.addr, now));
        assertFalse("GO9: an unregistered observer must not appear in aliveNodes",
                g.aliveNodes(now).contains(stranger.addr));
    }

    /**
     * Positive control. The byte-identical payload from
     * {@link #unregisteredObserverGossipIsDropped()} is admitted as soon as the
     * registry vouches for the observer. Without this test the negative case
     * above would be worthless — the drop could have been caused by a bad
     * signature, a stale timestamp, a replay verdict or a decode failure.
     */
    @Test
    public void sameObservationFromRegisteredObserverIsAdmitted() {
        Node peer = new Node();
        long now = System.currentTimeMillis();
        byte[] wire = signedWire(peer, TARGET, now);
        assertPayloadIsWellFormed(peer, wire);

        // Case 1 again, with exactly one thing changed: the registry's answer.
        TrustGossip rejecting = gossip(FakeMembers.with(TARGET));
        rejecting.messageArrived(TOPIC, new MqttMessage(wire));
        assertEquals("control precondition: unregistered observer is dropped",
                0, rejecting.remoteObservationsOf(TARGET, now).size());

        TrustGossip admitting = gossip(FakeMembers.with(TARGET, peer.addr));
        admitting.messageArrived(TOPIC, new MqttMessage(wire));

        List<NodeObservation> seen = admitting.remoteObservationsOf(TARGET, now);
        assertEquals("a registered observer's identical observation must be admitted,"
                + " proving the earlier drop was the membership check and nothing else",
                1, seen.size());
        assertTrue("the admitted observation must be attributed to the registered peer",
                observedBy(seen, peer.addr));
        assertTrue("a registered observer whose gossip just arrived must be alive",
                admitting.isAlive(peer.addr, now));
        assertTrue("a registered, fresh observer must appear in aliveNodes",
                admitting.aliveNodes(now).contains(peer.addr));
    }

    // =================================================================
    // Fail-closed.
    // =================================================================

    /**
     * {@link MemberRegistry} specifies that implementations fail <b>closed</b>:
     * when membership cannot be established the answer is {@code false}. This
     * models the two real ways that happens in
     * {@code IdentityRegistryMembers} — the registry coordinates are missing
     * from configuration, or the dev-inspect RPC failed with no cached answer —
     * and asserts the receive path honours the resulting {@code false} by
     * dropping, never by waving the observation through.
     */
    @Test
    public void failClosedRegistryDropsOtherwiseValidObservation() {
        Node peer = new Node();
        long now = System.currentTimeMillis();
        byte[] wire = signedWire(peer, TARGET, now);
        assertPayloadIsWellFormed(peer, wire);

        FakeMembers unavailable = FakeMembers.alwaysFalse();
        TrustGossip g = gossip(unavailable);

        g.messageArrived(TOPIC, new MqttMessage(wire));

        assertTrue("the fail-closed registry must have been consulted",
                unavailable.calls() > 0);
        assertEquals("a registry that cannot establish membership must cause the"
                + " observation to be dropped, not admitted (fail closed)",
                0, g.remoteObservationsOf(TARGET, now).size());
        assertFalse("fail-closed membership must also deny liveness",
                g.isAlive(peer.addr, now));
        assertEquals("fail-closed membership must leave the alive set at self only",
                1, g.aliveNodes(now).size());
    }

    /**
     * A contract-violating registry that <i>throws</i> instead of answering must
     * still never result in admission.
     *
     * <p>The assertion is deliberately agnostic about whether the exception
     * escapes {@code messageArrived}: what GO9 requires is that the observation
     * does not get in. (It does currently escape — the membership gate is not
     * wrapped — but it is thrown <i>before</i> any state is mutated, so the
     * stranger is never ingested. That escape is a robustness concern for the
     * MQTT callback thread, not a membership bypass, and is reported separately
     * rather than asserted here as desired behaviour.)
     */
    @Test
    public void throwingRegistryNeverAdmitsTheObserver() {
        Node peer = new Node();
        long now = System.currentTimeMillis();
        byte[] wire = signedWire(peer, TARGET, now);
        assertPayloadIsWellFormed(peer, wire);

        FakeMembers broken = FakeMembers.throwing();
        TrustGossip g = gossip(broken);

        // messageArrived must CONTAIN the failure. Paho's CommsCallback wraps
        // the callback in `catch (Throwable)` and tears the connection down in
        // response, so an escaping exception costs the node its MQTT link —
        // and with automatic reconnect that becomes a reconnect loop, i.e. a
        // remote peer can render this node gossip-deaf by choosing when we
        // consult a registry that happens to be failing. Dropping the message
        // is the required behaviour; propagating is a self-DoS.
        try {
            g.messageArrived(TOPIC, new MqttMessage(wire));
        } catch (RuntimeException escaped) {
            fail("messageArrived must not propagate " + escaped.getClass().getSimpleName()
                    + " out to the Paho callback thread (it tears down the MQTT"
                    + " connection); the message should have been dropped instead");
        }

        assertTrue("the throwing registry must have been consulted", broken.calls() > 0);

        // Reads must not admit the stranger either. They consult the same
        // throwing registry, so a throw here is equally acceptable to a denial —
        // what must never happen is a successful read that contains it.
        try {
            assertFalse("a registry that throws must never result in the observer's"
                    + " observation being admitted",
                    observedBy(g.remoteObservationsOf(TARGET, now), peer.addr));
        } catch (RuntimeException escaped) { /* denial by exception is acceptable */ }
        try {
            assertFalse("a registry that throws must never result in the observer"
                    + " being treated as alive", g.isAlive(peer.addr, now));
        } catch (RuntimeException escaped) { /* denial by exception is acceptable */ }
        try {
            assertFalse("a registry that throws must never let the observer into"
                    + " the alive set", g.aliveNodes(now).contains(peer.addr));
        } catch (RuntimeException escaped) { /* denial by exception is acceptable */ }
    }

    // =================================================================
    // The concrete attack B10 exists to stop: inflating the peer set.
    // =================================================================

    /**
     * The Sybil attack in its original form. Three throwaway keypairs each gossip
     * a flawlessly signed observation. Unregistered, they must not move the alive
     * count by one — which is what would otherwise stuff the peer-agreement
     * denominator {@code n} and hand the attacker the lowest-address submitter
     * election. The second half of the test registers the same three identities
     * and shows the count does move, proving the three payloads were genuinely
     * admissible and that the membership gate was the only thing stopping them.
     */
    @Test
    public void unregisteredObserversCannotInflateTheAliveNodeCount() {
        Node[] sybils = { new Node(), new Node(), new Node() };
        long now = System.currentTimeMillis();
        byte[][] wires = new byte[sybils.length][];
        for (int i = 0; i < sybils.length; i++) {
            wires[i] = signedWire(sybils[i], TARGET, now);
            assertPayloadIsWellFormed(sybils[i], wires[i]);
        }

        TrustGossip rejecting = gossip(FakeMembers.with(TARGET));
        for (byte[] w : wires) rejecting.messageArrived(TOPIC, new MqttMessage(w));

        Set<String> alive = rejecting.aliveNodes(now);
        assertEquals("GO9: unregistered Sybil observers must not inflate the peer"
                + " count — only this node itself may be alive here, got " + alive,
                1, alive.size());
        assertTrue("the only alive node must be self", alive.contains(SELF_ADDR));
        assertEquals("GO9: no Sybil observation may reach the aggregate",
                0, rejecting.remoteObservationsOf(TARGET, now).size());

        // Control: register the very same identities and replay the very same bytes.
        FakeMembers all = FakeMembers.with(TARGET);
        for (Node s : sybils) all.register(s.addr);
        TrustGossip admitting = gossip(all);
        for (byte[] w : wires) admitting.messageArrived(TOPIC, new MqttMessage(w));

        assertEquals("control: once registered, the same three observers do count"
                + " towards the peer set (self + 3)",
                4, admitting.aliveNodes(now).size());
        assertEquals("control: once registered, all three observations are admitted",
                3, admitting.remoteObservationsOf(TARGET, now).size());
    }

    /**
     * Membership is enforced on the <b>read</b> path too, not only at admission.
     * An observer admitted while registered and then de-registered on chain (the
     * revocation case) must stop counting immediately, without waiting for its
     * gossip to go stale. This is the second gate, inside
     * {@code TrustGossip.isAlive}.
     */
    @Test
    public void revokedObserverStopsCountingWithoutWaitingForStaleness() {
        Node peer = new Node();
        long now = System.currentTimeMillis();
        byte[] wire = signedWire(peer, TARGET, now);

        FakeMembers members = FakeMembers.with(TARGET, peer.addr);
        TrustGossip g = gossip(members);
        g.messageArrived(TOPIC, new MqttMessage(wire));

        assertEquals("precondition: a registered observer is admitted",
                1, g.remoteObservationsOf(TARGET, now).size());
        assertTrue("precondition: a registered observer is alive", g.isAlive(peer.addr, now));

        members.revoke(peer.addr);

        assertFalse("GO9: a de-registered observer must stop being alive at once,"
                + " even though its gossip is still well within the freshness window",
                g.isAlive(peer.addr, now));
        assertFalse("GO9: a de-registered observer must drop out of aliveNodes",
                g.aliveNodes(now).contains(peer.addr));
        assertEquals("GO9: a de-registered observer's already-stored observation must"
                + " no longer be served to the aggregate",
                0, g.remoteObservationsOf(TARGET, now).size());
    }
}
