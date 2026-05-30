package org.eclipse.om2m.sui.sdk;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters;
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;

/**
 * Sui Ed25519 signer.
 *
 * Sui signature format:
 *   - Intent message = [scope=0, version=0, app_id=0] || tx_bytes
 *   - Sign with Ed25519 over blake2b256(intent_message)
 *   - Wire format = base64([0x00 scheme] || sig(64) || pubkey(32))
 *
 * Keystore format (~/.sui/sui_config/sui.keystore) = JSON array of base64
 * strings, each = base64([0x00 scheme] || privkey(32)) for Ed25519 entries.
 */
public final class Ed25519Signer {

    public static final class Keypair {
        public final byte[] privKey;
        public final byte[] pubKey;
        public final byte[] address;  // 32 bytes, blake2b256(0x00 || pubkey)

        Keypair(byte[] privKey, byte[] pubKey, byte[] address) {
            this.privKey = privKey;
            this.pubKey = pubKey;
            this.address = address;
        }
    }

    /** Load all Ed25519 keypairs from a Sui keystore JSON file, keyed by 0x address. */
    public static Map<String, Keypair> loadKeystore(Path keystorePath) throws IOException {
        byte[] data = Files.readAllBytes(keystorePath);
        JsonNode arr = new ObjectMapper().readTree(data);
        Map<String, Keypair> out = new HashMap<>();
        for (JsonNode node : arr) {
            byte[] raw = Base64.getDecoder().decode(node.asText());
            if (raw.length != 33 || raw[0] != 0x00) continue;  // not Ed25519
            byte[] priv = new byte[32];
            System.arraycopy(raw, 1, priv, 0, 32);

            Ed25519PrivateKeyParameters skp = new Ed25519PrivateKeyParameters(priv, 0);
            byte[] pub = skp.generatePublicKey().getEncoded();

            // Sui address = blake2b256(0x00 || pubkey)
            byte[] addrInput = new byte[33];
            addrInput[0] = 0x00;
            System.arraycopy(pub, 0, addrInput, 1, 32);
            byte[] addr = Blake2b256.hash(addrInput);

            String addrHex = "0x" + bytesToHex(addr);
            out.put(addrHex, new Keypair(priv, pub, addr));
        }
        return out;
    }

    /** Sign and return base64 of [scheme || sig || pubkey]. */
    public static String signTransaction(byte[] txBytes, Keypair kp) {
        // Intent message = [0,0,0] || tx_bytes
        byte[] intentMsg = new byte[3 + txBytes.length];
        intentMsg[0] = 0; intentMsg[1] = 0; intentMsg[2] = 0;
        System.arraycopy(txBytes, 0, intentMsg, 3, txBytes.length);

        // Sui signs over blake2b256(intent_message)
        byte[] toSign = Blake2b256.hash(intentMsg);

        Ed25519PrivateKeyParameters skp = new Ed25519PrivateKeyParameters(kp.privKey, 0);
        org.bouncycastle.crypto.signers.Ed25519Signer signer = new org.bouncycastle.crypto.signers.Ed25519Signer();
        signer.init(true, skp);
        signer.update(toSign, 0, toSign.length);
        byte[] sig = signer.generateSignature();

        byte[] wire = new byte[1 + 64 + 32];
        wire[0] = 0x00;
        System.arraycopy(sig, 0, wire, 1, 64);
        System.arraycopy(kp.pubKey, 0, wire, 65, 32);
        return Base64.getEncoder().encodeToString(wire);
    }

    private static String bytesToHex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte v : b) sb.append(String.format("%02x", v & 0xFF));
        return sb.toString();
    }
}
