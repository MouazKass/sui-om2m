package org.eclipse.om2m.sui.trust;

import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters;

import java.nio.charset.StandardCharsets;

/**
 * Authenticated failover heartbeats, using the same Ed25519 key and address
 * binding as trust gossip ({@link GossipSig}).
 *
 * <p><b>Why.</b> v7 heartbeats were {@code "<addr>|0|<ts>"}, where the sender
 * address was self-declared and unauthenticated, and the broker allows
 * anonymous publishing. FailoverManager counts liveness only from the
 * chain-named parent's beats, which is meant to stop other nodes from
 * suppressing failover. But any node could put the PARENT's address in the
 * payload, keep a dead parent looking alive, and block failover indefinitely.
 *
 * <p>Wire format (version-tagged so legacy beats can never be mistaken for it):
 * <pre>  hb2|&lt;addr&gt;|&lt;epoch&gt;|&lt;ts-ms&gt;|&lt;flaggedPubKeyB64&gt;|&lt;sigB64&gt;</pre>
 * The signature covers {@code hb2|<addr>|<epoch>|<ts-ms>}. A beat is accepted
 * only if the signature verifies AND the public key derives to {@code <addr>},
 * so a node can sign beats only as itself. Replaying a captured genuine beat is
 * handled separately by FailoverManager's freshness window on {@code <ts-ms>}.
 */
public final class SignedBeacon {

    static final String TAG = "hb2";

    private final Ed25519PrivateKeyParameters key;
    private final String pubB64;
    private final String selfAddr;

    private SignedBeacon(Ed25519PrivateKeyParameters key, String pubB64, String selfAddr) {
        this.key = key;
        this.pubB64 = pubB64;
        this.selfAddr = selfAddr;
    }

    /**
     * Load this node's key from a Sui keystore (JSON array, first entry), the
     * same way TrustGossip does. Returns null if the key is missing or does not
     * derive to {@code selfAddr}: an unsigned node simply cannot assert
     * liveness, which fails safe (failover proceeds).
     */
    public static SignedBeacon fromKeystore(String keystorePath, String selfAddr) {
        try {
            if (keystorePath == null || selfAddr == null) return null;
            com.fasterxml.jackson.databind.JsonNode arr =
                new com.fasterxml.jackson.databind.ObjectMapper().readTree(new java.io.File(keystorePath));
            if (!arr.isArray() || arr.size() == 0) return null;
            Ed25519PrivateKeyParameters k = GossipSig.loadPrivateKey(arr.get(0).asText());
            String pub = GossipSig.publicKeyB64(k);
            if (!GossipSig.addressOf(pub).equalsIgnoreCase(selfAddr)) return null;
            return new SignedBeacon(k, pub, selfAddr);
        } catch (Exception e) {
            return null;
        }
    }

    /** Build from a raw Sui keystore entry (base64: flag byte + 32-byte seed). */
    public static SignedBeacon fromKeystoreEntry(String keystoreEntryB64) {
        Ed25519PrivateKeyParameters k = GossipSig.loadPrivateKey(keystoreEntryB64);
        String pub = GossipSig.publicKeyB64(k);
        return new SignedBeacon(k, pub, GossipSig.addressOf(pub));
    }

    public String address() { return selfAddr; }

    /** A signed heartbeat payload for (epoch, ts). */
    public String beat(long epoch, long tsMs) {
        String unsigned = TAG + "|" + selfAddr + "|" + epoch + "|" + tsMs;
        String sig = GossipSig.sign(key, unsigned.getBytes(StandardCharsets.UTF_8));
        return unsigned + "|" + pubB64 + "|" + sig;
    }

    /** A verified heartbeat: who sent it and their claimed timestamp. */
    public static final class Verified {
        public final String sender;
        public final long tsMs;
        Verified(String sender, long tsMs) { this.sender = sender; this.tsMs = tsMs; }
    }

    /**
     * Parse and verify a heartbeat. Returns null for anything that is not a
     * well-formed hb2 beat, signed by the key of the address it names. Legacy
     * unsigned beats return null, so they can never count.
     */
    public static Verified verify(String payload) {
        if (payload == null) return null;
        String[] p = payload.split("\\|", -1);
        if (p.length != 6 || !TAG.equals(p[0])) return null;
        String addr = p[1];
        long ts;
        try { Long.parseLong(p[2]); ts = Long.parseLong(p[3]); }
        catch (NumberFormatException e) { return null; }
        String unsigned = p[0] + "|" + p[1] + "|" + p[2] + "|" + p[3];
        try {
            if (!GossipSig.verify(p[4], unsigned.getBytes(StandardCharsets.UTF_8), p[5])) return null;
            if (!GossipSig.addressOf(p[4]).equalsIgnoreCase(addr)) return null;
        } catch (RuntimeException e) {
            return null;
        }
        return new Verified(addr, ts);
    }
}
