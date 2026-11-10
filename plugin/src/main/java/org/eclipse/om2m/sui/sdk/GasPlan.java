package org.eclipse.om2m.sui.sdk;

import java.math.BigInteger;
import java.util.Collections;
import java.util.List;

/**
 * How one transaction pays for gas: from an owned {@code Coin<SUI>} or from the
 * sender's SUI address balance.
 *
 * <p>Why both exist: the testnet faucet (v3) pays into the recipient's address
 * balance, not into a coin object. A node topped up by the gas watchdog
 * therefore holds most of its SUI where coin-only gas selection cannot see it
 * (observed 2026-11-10: rpi2 had 2.0 SUI in its address balance and 0.38 SUI in
 * coins). Sui lets a programmable transaction pay gas from the address balance
 * when {@code GasData.payment} is empty and the expiration is
 * {@code ValidDuring} with both epoch bounds set.
 *
 * <p>Selection ({@link #choose}): a coin when one covers the budget (the path
 * used since v1), otherwise the address balance when it covers the budget,
 * otherwise nothing, reported with the usual "no gas coin" wording so the FM5
 * gas-exhaustion signal still fires. {@code sui.gas.source} can pin either
 * source.
 */
public final class GasPlan {

    public enum Source { COIN, ADDRESS_BALANCE }

    /** sui.gas.source values. */
    public enum Mode {
        AUTO, COIN, ADDRESS;

        public static Mode parse(String s) {
            if (s == null || s.trim().isEmpty()) return AUTO;
            String v = s.trim().toLowerCase(java.util.Locale.ROOT);
            if ("auto".equals(v)) return AUTO;
            if ("coin".equals(v)) return COIN;
            if ("address".equals(v) || "address-balance".equals(v)) return ADDRESS;
            throw new IllegalArgumentException("sui.gas.source must be auto|coin|address, got: " + s);
        }
    }

    public final Source source;
    public final List<SuiPtbEncoder.ObjectRef> payment;
    public final SuiPtbEncoder.Expiration expiration;

    private GasPlan(Source source, List<SuiPtbEncoder.ObjectRef> payment,
                    SuiPtbEncoder.Expiration expiration) {
        this.source = source;
        this.payment = payment;
        this.expiration = expiration;
    }

    public static GasPlan coin(SuiPtbEncoder.ObjectRef coin) {
        return new GasPlan(Source.COIN, Collections.singletonList(coin), SuiPtbEncoder.Expiration.NONE);
    }

    /** Valid for the current epoch and the next one, so an epoch change mid-flight does not void it. */
    public static GasPlan addressBalance(long epoch, byte[] chainId32, long nonce) {
        return new GasPlan(Source.ADDRESS_BALANCE,
                Collections.<SuiPtbEncoder.ObjectRef>emptyList(),
                SuiPtbEncoder.Expiration.validDuring(epoch, epoch + 1, chainId32, nonce));
    }

    /** Short form for logs. */
    public String describe() {
        if (source == Source.COIN) {
            SuiPtbEncoder.ObjectRef c = payment.get(0);
            return "coin(ver=" + c.version + ")";
        }
        return "address-balance(epochs " + expiration.minEpoch + ".." + expiration.maxEpoch
                + ", nonce=" + expiration.nonce + ")";
    }

    /** Inputs to {@link #choose}, fetched from the chain by {@link SuiObjectFetcher#planGas}. */
    public interface Chain {
        /** A coin with balance >= budget, or null if none. */
        SuiPtbEncoder.ObjectRef coinCovering(long budget) throws java.io.IOException;
        BigInteger addressBalance() throws java.io.IOException;
        long epoch() throws java.io.IOException;
        byte[] chainId() throws java.io.IOException;
    }

    /**
     * Pure selection policy. Throws an IOException containing "no gas coin"
     * (the FM5 marker, see FailoverManager.isGasExhaustion) when neither
     * permitted source covers the budget.
     */
    public static GasPlan choose(Chain chain, long budget, Mode mode, long nonce)
            throws java.io.IOException {
        if (mode != Mode.ADDRESS) {
            SuiPtbEncoder.ObjectRef c = chain.coinCovering(budget);
            if (c != null) return coin(c);
        }
        BigInteger ab = BigInteger.ZERO;
        if (mode != Mode.COIN) {
            ab = chain.addressBalance();
            if (ab.compareTo(BigInteger.valueOf(budget)) >= 0) {
                return addressBalance(chain.epoch(), chain.chainId(), nonce);
            }
        }
        throw new java.io.IOException("no gas coin with balance >= " + budget
                + (mode == Mode.COIN ? "" : " and address balance " + ab + " < " + budget)
                + " (sui.gas.source=" + mode.name().toLowerCase(java.util.Locale.ROOT) + ")");
    }
}
