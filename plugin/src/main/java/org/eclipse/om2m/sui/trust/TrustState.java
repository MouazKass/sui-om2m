package org.eclipse.om2m.sui.trust;

/**
 * Per-target trust state held by the engine: the EMA-smoothed score, the score
 * that was last written on-chain (used to detect tier-boundary crossings), the
 * B9 anti-flap bookkeeping for a crossing that is still being confirmed, and
 * the write-pacing / decay re-anchoring bookkeeping.
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

    // === B9 hysteresis: a candidate crossing must hold for N ticks ===
    /** Tier we are currently counting towards, or -1 when nothing is pending. */
    int pendingTier = -1;
    /** Consecutive ticks {@link #pendingTier} has been the candidate. */
    int pendingTicks;

    // === On-chain write discipline (trust.move A12 + decay) ===
    /**
     * When this node last SUBMITTED a write for the target (any outcome).
     * Pacing: no new write before {@code lastWriteMs + minWriteIntervalMs},
     * because trust.move aborts (and still charges gas) for a write less than
     * 60 s after the entry's previous one. Initialised to the creation time of
     * this state so a freshly restarted engine — which cannot know when its
     * previous incarnation last wrote — also waits one interval.
     */
    long lastWriteMs;
    /** Extra embargo after a failed write (rate-limit backoff / error backoff). */
    long backoffUntilMs;
    /** Consecutive non-rate-limit write failures, drives exponential backoff. */
    int consecutiveFailures;
    /**
     * When a write by THIS node last succeeded, i.e. re-anchored the entry's
     * on-chain {@code last_update_ms} (decay clock). 0 = unknown (never, or
     * not since restart), which makes a re-attestation due immediately. A mere
     * read does not count: it does not stop decay.
     */
    long lastAnchorMs;
    /**
     * Per-target write cap learned from an on-chain E_DELTA_TOO_LARGE abort
     * (config disagrees with trust::MAX_DELTA). 0 = use the configured cap.
     */
    long learnedDeltaCap;

    TrustState() {
        this(0L);
    }

    TrustState(long createdAtMs) {
        this.ema = 50.0;          // neutral until seeded from chain
        this.lastOnChain = 50.0;
        this.seeded = false;
        this.lastWriteMs = createdAtMs;
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

    /**
     * Count one tick towards {@code tier}.
     *
     * @return the number of consecutive ticks {@code tier} has now been the
     *         pending candidate (1 on the first tick).
     */
    int observeCandidateTier(int tier) {
        if (pendingTier != tier) {
            pendingTier = tier;
            pendingTicks = 1;
        } else {
            pendingTicks++;
        }
        return pendingTicks;
    }

    /** Forget any pending crossing (score fell back inside the dead-band). */
    void clearPendingTier() {
        pendingTier = -1;
        pendingTicks = 0;
    }
}
