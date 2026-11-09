package org.eclipse.om2m.sui.trust;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Base64;

import org.junit.Test;

/**
 * Failover heartbeats must be authenticated. v7 beats were "<addr>|0|<ts>",
 * where the sender address was self-declared, so any node could forge the
 * parent's beats and block failover indefinitely. A beat now counts only if
 * it is signed by the key of the address it names.
 */
public class SignedBeaconTest {

    /** A Sui keystore entry: base64(flag 0x00 = Ed25519, then a 32-byte seed). */
    static String entry(int seedByte) {
        byte[] b = new byte[33];
        b[0] = 0x00;
        Arrays.fill(b, 1, 33, (byte) seedByte);
        return Base64.getEncoder().encodeToString(b);
    }

    private static final SignedBeacon A = SignedBeacon.fromKeystoreEntry(entry(1));
    private static final SignedBeacon B = SignedBeacon.fromKeystoreEntry(entry(2));

    @Test
    public void genuineBeatVerifiesAndCarriesSenderAndTimestamp() {
        SignedBeacon.Verified v = SignedBeacon.verify(A.beat(0L, 1_700_000_000_000L));
        assertNotNull("a genuine beat must verify", v);
        assertEquals(A.address(), v.sender);
        assertEquals(1_700_000_000_000L, v.tsMs);
    }

    @Test
    public void beatClaimingAnotherNodesAddressIsRejected() {
        // The v7 attack: keep the signer's own key, but claim the parent's address.
        String forged = A.beat(0L, 1L).replace(A.address(), B.address());
        assertNull("a node must not be able to speak as another node", SignedBeacon.verify(forged));
    }

    @Test
    public void tamperedTimestampIsRejected() {
        String beat = A.beat(0L, 1000L);
        String tampered = beat.replace("|1000|", "|9999999999999|");
        assertNull("the timestamp is covered by the signature", SignedBeacon.verify(tampered));
    }

    @Test
    public void legacyUnsignedBeatIsRejected() {
        assertNull("the v7 unsigned format must never count",
                   SignedBeacon.verify(A.address() + "|0|" + System.currentTimeMillis()));
    }

    @Test
    public void validSignatureFromTheWrongKeyIsRejected() {
        // Re-sign A's claimed fields with B's key: the signature is valid, but
        // B's public key does not derive to A's address.
        String a = A.beat(0L, 5L);
        String b = B.beat(0L, 5L);
        String[] pa = a.split("\\|", -1), pb = b.split("\\|", -1);
        String frank = pa[0] + "|" + pa[1] + "|" + pa[2] + "|" + pa[3] + "|" + pb[4] + "|" + pb[5];
        assertNull(SignedBeacon.verify(frank));
    }

    @Test
    public void malformedPayloadsAreRejected() {
        assertNull(SignedBeacon.verify(null));
        assertNull(SignedBeacon.verify(""));
        assertNull(SignedBeacon.verify("hb2|x|y|z|p|s"));
        assertNull(SignedBeacon.verify("hb1|" + A.beat(0L, 1L).substring(4)));
    }

    @Test
    public void keystoreWhoseKeyDoesNotMatchTheNodeAddressGivesNoSigner() throws Exception {
        File ks = File.createTempFile("sui", ".keystore");
        ks.deleteOnExit();
        Files.write(ks.toPath(), ("[\"" + entry(1) + "\"]").getBytes(StandardCharsets.UTF_8));
        assertNotNull(SignedBeacon.fromKeystore(ks.getPath(), A.address()));
        assertNull("misconfigured key must not sign as someone else",
                   SignedBeacon.fromKeystore(ks.getPath(), B.address()));
        assertNull(SignedBeacon.fromKeystore("/nonexistent/sui.keystore", A.address()));
    }
}
