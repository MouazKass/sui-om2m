package org.eclipse.om2m.sui.trust;

import java.util.Base64;
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters;
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters;
import org.bouncycastle.crypto.signers.Ed25519Signer;
import org.bouncycastle.crypto.digests.Blake2bDigest;

/**
 * Ed25519 signing/verification for trust gossip, bound to Sui addresses.
 *
 * <p>A Sui ed25519 address is BLAKE2b-256(0x00 || pubkey). We sign the raw
 * gossip payload bytes (no Sui transaction-intent prefix \u2014 these are not
 * transactions) and ship the signature plus the flag-prefixed public key.
 * A verifier recomputes the address from the shipped public key and checks it
 * matches the claimed observer address, then verifies the signature. This
 * makes forging another node's observerAddr cryptographically infeasible.
 */
final class GossipSig {

    private GossipSig() {}

    /** Load a 32-byte ed25519 private seed from a Sui keystore entry (0x00 || seed, base64). */
    static Ed25519PrivateKeyParameters loadPrivateKey(String keystoreEntryB64) {
        byte[] raw = Base64.getDecoder().decode(keystoreEntryB64);
        if (raw.length != 33 || raw[0] != 0x00) {
            throw new IllegalArgumentException("not an ed25519 keystore entry");
        }
        byte[] seed = new byte[32];
        System.arraycopy(raw, 1, seed, 0, 32);
        return new Ed25519PrivateKeyParameters(seed, 0);
    }

    /** The flag-prefixed public key (0x00 || pubkey), base64, as Sui reports it. */
    static String publicKeyB64(Ed25519PrivateKeyParameters priv) {
        byte[] pub = priv.generatePublicKey().getEncoded(); // 32 bytes
        byte[] flagged = new byte[33];
        flagged[0] = 0x00;
        System.arraycopy(pub, 0, flagged, 1, 32);
        return Base64.getEncoder().encodeToString(flagged);
    }

    /** Sui address (0x-prefixed lowercase hex) derived from a flag-prefixed pubkey. */
    static String addressOf(String flaggedPubKeyB64) {
        byte[] flagged = Base64.getDecoder().decode(flaggedPubKeyB64);
        Blake2bDigest d = new Blake2bDigest(256);
        d.update(flagged, 0, flagged.length);
        byte[] out = new byte[32];
        d.doFinal(out, 0);
        StringBuilder sb = new StringBuilder(66).append("0x");
        for (byte b : out) sb.append(String.format("%02x", b & 0xff));
        return sb.toString();
    }

    /** Sign payload bytes; returns base64 signature (64 bytes). */
    static String sign(Ed25519PrivateKeyParameters priv, byte[] payload) {
        Ed25519Signer s = new Ed25519Signer();
        s.init(true, priv);
        s.update(payload, 0, payload.length);
        return Base64.getEncoder().encodeToString(s.generateSignature());
    }

    /** Verify a base64 signature against payload using a flag-prefixed pubkey. */
    static boolean verify(String flaggedPubKeyB64, byte[] payload, String sigB64) {
        try {
            byte[] flagged = Base64.getDecoder().decode(flaggedPubKeyB64);
            if (flagged.length != 33 || flagged[0] != 0x00) return false;
            byte[] pub = new byte[32];
            System.arraycopy(flagged, 1, pub, 0, 32);
            Ed25519PublicKeyParameters pk = new Ed25519PublicKeyParameters(pub, 0);
            Ed25519Signer s = new Ed25519Signer();
            s.init(false, pk);
            s.update(payload, 0, payload.length);
            return s.verifySignature(Base64.getDecoder().decode(sigB64));
        } catch (Exception e) {
            return false;
        }
    }
}
