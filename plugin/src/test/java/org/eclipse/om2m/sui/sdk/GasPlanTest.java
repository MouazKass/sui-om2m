package org.eclipse.om2m.sui.sdk;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.IOException;
import java.math.BigInteger;
import java.util.Collections;
import java.util.concurrent.atomic.AtomicInteger;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.Test;

/**
 * Address-balance gas (faucet v3 pays the address balance, not a coin).
 *
 * The golden vector was produced by an independent Python encoder whose layout
 * testnet's simulateTransaction accepted on 2026-11-10 (status SUCCESS), and
 * whose negative controls testnet rejected: a truncated nonce failed with
 * "unexpected end of input", a zero chain field with "Transaction chain ID ...
 * does not match network chain ID".
 */
public class GasPlanTest {

    static final String SENDER = "0x4be6060abaff0b4b6b7229558887f5f054cbe7d9836ba56eff35d848e13dc1f5";
    static final String TESTNET_CHAIN = "69WiPg3DAQiwdxfncX6wYQ2siKwAe6L9BZthQea3JNMD";
    static final String GOLDEN =
        "000000004be6060abaff0b4b6b7229558887f5f054cbe7d9836ba56eff35d848e13dc1f5"
        + "004be6060abaff0b4b6b7229558887f5f054cbe7d9836ba56eff35d848e13dc1f5"
        + "e803000000000000002d310100000000"
        + "0201ff040000000000000100050000000000000000"
        + "204c78adacf2a2f5ad80f27ed7d54aa69d3a78f1ca67fdef9ecf5754f5b8bb77b0"
        + "efbeadde";

    static byte[] hex(String h) {
        byte[] b = new byte[h.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(h.substring(2 * i, 2 * i + 2), 16);
        return b;
    }

    static byte[] chain() { return BcsEncoder.base58Decode(TESTNET_CHAIN); }

    static SuiPtbEncoder.ObjectRef coinRef() {
        return new SuiPtbEncoder.ObjectRef(new byte[32], 7L, new byte[32]);
    }

    @Test
    public void addressBalanceGasMatchesTheTestnetValidatedLayout() {
        byte[] tx = new SuiPtbEncoder().encodeTransactionData(
            BcsEncoder.hexTo32(SENDER), GasPlan.addressBalance(1279, chain(), 0xDEADBEEFL), 1000L, 20_000_000L);
        assertArrayEquals(hex(GOLDEN), tx);
    }

    @Test
    public void coinGasIsUnchangedByteForByte() {
        // The legacy 4-arg form and the coin plan must produce identical bytes (expiration None).
        SuiPtbEncoder enc = new SuiPtbEncoder();
        byte[] legacy = enc.encodeTransactionData(BcsEncoder.hexTo32(SENDER),
            Collections.singletonList(coinRef()), 1000L, 20_000_000L);
        byte[] viaPlan = enc.encodeTransactionData(BcsEncoder.hexTo32(SENDER),
            GasPlan.coin(coinRef()), 1000L, 20_000_000L);
        assertArrayEquals(legacy, viaPlan);
        assertEquals("expiration None is the last byte", 0, legacy[legacy.length - 1]);
    }

    @Test
    public void emptyPaymentWithoutValidDuringIsRefused() {
        try {
            new SuiPtbEncoder().encodeTransactionData(BcsEncoder.hexTo32(SENDER),
                Collections.<SuiPtbEncoder.ObjectRef>emptyList(), 1000L, 1L);
            fail("empty payment without ValidDuring must be refused");
        } catch (IllegalArgumentException expected) { /* ok */ }
    }

    @Test
    public void validDuringBoundsAreEnforced() {
        for (long[] bad : new long[][] {{5, 7}, {5, 4}, {-1, 0}}) {
            try {
                SuiPtbEncoder.Expiration.validDuring(bad[0], bad[1], chain(), 1);
                fail("accepted " + bad[0] + ".." + bad[1]);
            } catch (IllegalArgumentException expected) { /* ok */ }
        }
        SuiPtbEncoder.Expiration.validDuring(5, 5, chain(), 1);
        SuiPtbEncoder.Expiration.validDuring(5, 6, chain(), 0xFFFFFFFFL);
    }

    /** Scripted chain view for the selection policy. */
    static final class FakeChain implements GasPlan.Chain {
        final SuiPtbEncoder.ObjectRef coin; final long coinBal; final BigInteger addr;
        final AtomicInteger addrReads = new AtomicInteger();
        FakeChain(SuiPtbEncoder.ObjectRef coin, long coinBal, long addr) {
            this.coin = coin; this.coinBal = coinBal; this.addr = BigInteger.valueOf(addr);
        }
        @Override public SuiPtbEncoder.ObjectRef coinCovering(long b) { return coin != null && coinBal >= b ? coin : null; }
        @Override public BigInteger addressBalance() { addrReads.incrementAndGet(); return addr; }
        @Override public long epoch() { return 1279; }
        @Override public byte[] chainId() { return chain(); }
    }

    @Test
    public void autoPrefersACoinThatCoversTheBudget() throws IOException {
        FakeChain c = new FakeChain(coinRef(), 50, 1_000);
        GasPlan p = GasPlan.choose(c, 50, GasPlan.Mode.AUTO, 1);
        assertEquals(GasPlan.Source.COIN, p.source);
        assertEquals(0, c.addrReads.get());
    }

    @Test
    public void autoFallsBackToTheAddressBalanceWhenCoinsRunDry() throws IOException {
        // The live failure: 0.38 SUI in coins below a larger budget, 2 SUI from the faucet in the address balance.
        GasPlan p = GasPlan.choose(new FakeChain(coinRef(), 10, 100), 100, GasPlan.Mode.AUTO, 42);
        assertEquals(GasPlan.Source.ADDRESS_BALANCE, p.source);
        assertTrue(p.payment.isEmpty());
        assertTrue(p.expiration.isValidDuring());
        assertEquals(1279, p.expiration.minEpoch);
        assertEquals(1280, p.expiration.maxEpoch);
        assertEquals(42, p.expiration.nonce);
    }

    @Test
    public void neitherSourceCoveringTheBudgetIsReportedAsGasExhaustion() {
        try {
            GasPlan.choose(new FakeChain(coinRef(), 10, 99), 100, GasPlan.Mode.AUTO, 1);
            fail("must throw");
        } catch (IOException e) {
            assertTrue(e.getMessage(), e.getMessage().startsWith("no gas coin"));
            assertTrue(e.getMessage(), e.getMessage().contains("address balance 99"));
        }
    }

    @Test
    public void coinModeNeverTouchesTheAddressBalance() {
        FakeChain c = new FakeChain(null, 0, 1_000_000);
        try {
            GasPlan.choose(c, 100, GasPlan.Mode.COIN, 1);
            fail("must throw");
        } catch (IOException e) {
            assertEquals(0, c.addrReads.get());
        }
    }

    @Test
    public void addressModeSkipsCoins() throws IOException {
        GasPlan p = GasPlan.choose(new FakeChain(coinRef(), 1_000, 100), 100, GasPlan.Mode.ADDRESS, 1);
        assertEquals(GasPlan.Source.ADDRESS_BALANCE, p.source);
    }

    @Test
    public void modeParsing() {
        assertEquals(GasPlan.Mode.AUTO, GasPlan.Mode.parse(null));
        assertEquals(GasPlan.Mode.AUTO, GasPlan.Mode.parse(" "));
        assertEquals(GasPlan.Mode.COIN, GasPlan.Mode.parse("Coin"));
        assertEquals(GasPlan.Mode.ADDRESS, GasPlan.Mode.parse("address-balance"));
        try { GasPlan.Mode.parse("both"); fail(); } catch (IllegalArgumentException expected) { /* ok */ }
    }

    @Test
    public void balancesAreReadSeparately() throws Exception {
        JsonNode d = new ObjectMapper().readTree(
            "{\"address\":{\"balance\":{\"coinBalance\":\"377761145\",\"addressBalance\":\"2000000000\","
            + "\"totalBalance\":\"2377761145\"}}}");
        SuiObjectFetcher.SuiBalance b = SuiObjectFetcher.parseSuiBalance(d, SENDER);
        assertEquals(new BigInteger("377761145"), b.coin);
        assertEquals(new BigInteger("2000000000"), b.address);
        assertEquals(new BigInteger("2377761145"), b.total);
        SuiObjectFetcher.SuiBalance none =
            SuiObjectFetcher.parseSuiBalance(new ObjectMapper().readTree("{\"address\":null}"), SENDER);
        assertEquals(BigInteger.ZERO, none.address);
    }

    @Test
    public void chainIdentifierDecodesToTheGenesisDigest() throws Exception {
        byte[] c = SuiObjectFetcher.parseChainIdentifier(
            new ObjectMapper().readTree("{\"chainIdentifier\":\"" + TESTNET_CHAIN + "\"}"));
        assertEquals(32, c.length);
        assertEquals(0x4c, c[0] & 0xFF);   // testnet's short id is 4c78adac
        assertEquals(0x78, c[1] & 0xFF);
        try {
            SuiObjectFetcher.parseChainIdentifier(new ObjectMapper().readTree("{}"));
            fail();
        } catch (IOException expected) { assertNull(null); }
    }
}
