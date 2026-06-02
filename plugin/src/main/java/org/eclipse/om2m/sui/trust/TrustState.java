package org.eclipse.om2m.sui.trust;

/**
 * Per-target trust state held by the engine: the EMA-smoothed score and the
 * score that was last written on-chain (used to detect tier-boundary crossings).
 *
 * <p>Not shared across threads — the engine touches each {@code TrustState}
 * only from its single tick thread — so no synchronisation is needed here.
 */
final class TrustState {

    /** EMA-smoothed trust in [0,100]. Initialised from the on-chain score. */
    double ema;

    /** The score most recently committed on-chain (or the seed at startup). */
    double lastOnChain;

    /** Whether {@link #lastOnChain} has been established yet. */
    boolean seeded;

    TrustState() {
        this.ema = 50.0;          // neutral until seeded from chain
        this.lastOnChain = 50.0;
        this.seeded = false;
    }

    void seed(double onChainScore) {
        this.ema = onChainScore;
        this.lastOnChain = onChainScore;
        this.seeded = true;
    }

    /** Apply one EMA step against a fresh local score. */
    void updateEma(double localScore, double alpha) {
        this.ema = alpha * localScore + (1.0 - alpha) * this.ema;
    }
}
