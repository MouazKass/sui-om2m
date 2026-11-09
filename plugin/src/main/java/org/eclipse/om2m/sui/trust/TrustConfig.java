package org.eclipse.om2m.sui.trust;

import java.util.Properties;

/**
 * Configuration for the trust scoring engine.
 *
 * <p>All weights, the EMA smoothing factor, the rolling-window length, the
 * observation period, the tier boundaries and the tier hysteresis are loaded
 * from {@code sui.properties} so they can be tuned per deployment without
 * recompiling.
 *
 * <p><b>B11/B12 — 8-signal scheme.</b> The original scheme had eleven signals,
 * three of which were not real measurements:
 * <ul>
 *   <li><i>MQTT mismatch</i> (weight 5) — {@code setMqttMismatchFlag} had zero
 *       call sites, so the signal was a constant 1.0 for every node: five free
 *       points, never removable.</li>
 *   <li><i>Impersonation</i> (weight 8) — its only writer flagged the
 *       <i>claimed</i> observer address on a failed signature/address-binding
 *       check, i.e. it penalised the victim of a forgery, not the forger (B2).
 *       With that inverted attribution removed the signal has no writer left.</li>
 *   <li><i>PTB abort rate</i> (weight 10) — {@code recordPtbResult} was called
 *       from {@code SuiDasService.doExecute} with the <i>same</i> {@code granted}
 *       boolean already passed to {@code recordRequest}, so one denied access
 *       decision was counted twice: once as a denied-burst event and once as a
 *       PTB abort. It is merged into the denied-decisions signal, whose
 *       {@code 1 - denied/20} shape is unchanged but whose weight absorbs the
 *       abort weight.</li>
 * </ul>
 *
 * <pre>
 *   Group 1 — Protocol level (50%)
 *     heartbeat            25
 *     malformed payload    10
 *     request-rate ceiling 10
 *     clock drift           5
 *
 *   Group 2 — Access pattern (40%)
 *     denied decisions     25
 *     out-of-baseline      10
 *     inactive-period       5
 *
 *   Group 3 — Peer attestation (10%)
 *     garbage payload      10
 * </pre>
 *
 * The eight weights sum to 100, so a perfectly behaving node scores 100 and a
 * completely failed node scores 0.
 */
public final class TrustConfig {

    // === Group 1 — Protocol-level weights ===
    public final double wHeartbeat;
    public final double wMalformed;
    public final double wRate;
    public final double wClock;

    // === Group 2 — Access-pattern weights ===
    /** Denied access decisions (absorbed the old ptb_abort weight — B12). */
    public final double wDeniedBurst;
    public final double wHistorical;
    public final double wInactive;

    // === Group 3 — Peer-attestation weights ===
    public final double wGarbage;

    // === EMA ===
    /** Smoothing factor in [0,1]. 0.3 = new observation counts 30%, history 70%. */
    public final double emaAlpha;

    // === Timing ===
    /** How often the engine recomputes scores (ms). Design: 1000 (1 second). */
    public final long tickPeriodMs;
    /** Rolling observation window length (ms). Design: 60000 (60 seconds). */
    public final long windowMs;
    /** Expected interval between heartbeats from a healthy node (ms). */
    public final long heartbeatPeriodMs;

    // === Peer attestation ===
    /** A peer's gossip is "fresh" (node considered alive) if heard within
     *  this many ms. Used by the deterministic-submitter rule. */
    public final long peerLivenessMs;

    // === Detection thresholds (normalisers for the health functions) ===
    /** Request rate (requests within the window) at/above which rate_health = 0. */
    public final int rateCeiling;
    /** Clock drift (ms) at/above which clock_health = 0. */
    public final long maxClockDriftMs;
    /** Denied-decision count within the window at/above which denied_health = 0. */
    public final int deniedBurstThreshold;
    /** Warm-up period (ms) during which the per-node resource baseline is learned. */
    public final long baselineWarmupMs;
    /** Silence gap (ms): a request after this much inactivity is "off-hours". */
    public final long inactivityGapMs;

    // === Tier boundaries (must mirror evolution.move) ===
    /** Sorted ascending. A score crossing any of these triggers an on-chain update. */
    public final int[] tierBoundaries;

    // === B9: tier hysteresis (anti-flap) ===
    /** Score margin (points) the EMA must clear a boundary by before the
     *  crossing counts. 0 disables the dead-band. */
    public final double tierHysteresis;
    /** Consecutive ticks the new tier must hold before the crossing is acted on. */
    public final int tierConfirmTicks;

    // === On-chain submission ===
    public final long gasBudget;

    // === On-chain write discipline (must mirror move/sources/trust.move) ===
    /**
     * {@code trust.max.delta} (default 15). Largest magnitude a single
     * {@code increase_guarded}/{@code decrease_guarded} write may carry. Must
     * equal {@code trust::MAX_DELTA}: a larger write aborts on-chain with
     * {@code E_DELTA_TOO_LARGE} (6) and still pays gas. Bigger moves are
     * applied as several capped steps.
     */
    public final long maxDelta;
    /**
     * {@code trust.min.write.interval.ms} (default 65000). Minimum gap between
     * two writes this node submits for the same target. {@code trust.move}
     * rejects a write less than {@code MIN_INTERVAL_MS} (60000) after the
     * entry's {@code last_update_ms} with {@code E_RATE_LIMITED} (7); the extra
     * 5 s absorbs clock skew between this node and the chain clock. Must be
     * at least 60000.
     */
    public final long minWriteIntervalMs;
    /**
     * {@code trust.reattest.period.ms} (default 43200000 = 12 h). On-chain
     * scores lose 1 point per FULL day since the entry's last write, so a
     * stable, healthy node that is never written decays to 0. The submitter
     * re-writes (re-attests) every live target whose on-chain decay clock it
     * has not re-anchored for this long. Must be positive and, together with
     * {@link #minWriteIntervalMs}, stay under one day so a decay point never
     * accrues.
     */
    public final long reattestPeriodMs;

    // === EMA persistence ===
    public final String emaPersistPath;
    public final long   emaPersistPeriodMs;

    // === B6: observer restart epoch persistence ===
    public final String epochPersistPath;

    // === B10: on-chain membership check (identity::is_registered) ===
    /** Fullnode RPC endpoint used for the membership dev-inspect. */
    public final String rpcUrl;
    /** Deployed package ID holding the {@code identity} module. */
    public final String packageId;
    /** Shared {@code identity::Registry} object ID. */
    public final String identityRegistryId;
    /** How long a membership answer stays cached (ms). */
    public final long membershipCacheTtlMs;

    /** {@code trust::MIN_INTERVAL_MS}: on-chain minimum gap between writes. */
    static final long MOVE_MIN_INTERVAL_MS = 60_000L;
    /** {@code trust::MS_PER_DAY}: decay granularity (1 point per full day). */
    static final long MOVE_MS_PER_DAY = 86_400_000L;

    private TrustConfig(Properties p) {
        // B11/B12: 8 signals, 100 points. ptb_abort / impersonation /
        // mqtt_mismatch are gone; their weight moved to heartbeat, denied
        // decisions, out-of-baseline, inactivity and garbage.
        this.wHeartbeat     = d(p, "trust.weight.heartbeat",      25);
        this.wMalformed     = d(p, "trust.weight.malformed",      10);
        this.wRate          = d(p, "trust.weight.rate",           10);
        this.wClock         = d(p, "trust.weight.clock",           5);
        this.wDeniedBurst   = d(p, "trust.weight.denied_burst",   25);
        this.wHistorical    = d(p, "trust.weight.historical",     10);
        this.wInactive      = d(p, "trust.weight.inactive",        5);
        this.wGarbage       = d(p, "trust.weight.garbage",        10);

        this.emaAlpha       = d(p, "trust.ema.alpha",            0.30);

        this.tickPeriodMs       = l(p, "trust.tick.period.ms",      1_000);
        this.windowMs           = l(p, "trust.window.ms",         60_000);
        this.heartbeatPeriodMs  = l(p, "failover.heartbeat.period.ms", 5_000);

        // B3: the peer-agreement threshold is no longer a fixed constant. It is
        // derived per aggregation as k = floor((n-1)/2) + 1 over the admitted
        // observers, so it carries a real Byzantine-fault bound.
        this.peerLivenessMs         = l(p, "trust.peer.liveness.ms", 30_000);

        this.rateCeiling          = i(p, "trust.rate.ceiling",        300);
        this.maxClockDriftMs      = l(p, "trust.clock.max.drift.ms", 5_000);
        this.deniedBurstThreshold = i(p, "trust.denied.burst.threshold", 20);
        this.baselineWarmupMs     = l(p, "trust.baseline.warmup.ms", 300_000);
        this.inactivityGapMs      = l(p, "trust.inactivity.gap.ms", 1_800_000);

        this.tierBoundaries = parseTiers(
            p.getProperty("trust.tier.boundaries", "0,25,50,75,90"));
        this.tierHysteresis   = d(p, "trust.tier.hysteresis", 2.0);
        this.tierConfirmTicks = i(p, "trust.tier.confirm.ticks", 2);

        this.gasBudget = l(p, "sui.gas.budget", 20_000_000);
        this.maxDelta           = l(p, "trust.max.delta",              15);
        this.minWriteIntervalMs = l(p, "trust.min.write.interval.ms", 65_000);
        this.reattestPeriodMs   = l(p, "trust.reattest.period.ms",    43_200_000);
        this.emaPersistPath     = p.getProperty("trust.ema.persist.path",
                                                 "/tmp/trust-ema.properties").trim();
        this.emaPersistPeriodMs = l(p, "trust.ema.persist.period.ms", 30_000);
        this.epochPersistPath   = p.getProperty("trust.epoch.persist.path",
                                                 this.emaPersistPath + ".epoch").trim();

        // Read from the same sui.properties keys the rest of the plugin uses,
        // so B10 needs no new configuration and no change to the activator.
        this.rpcUrl             = p.getProperty("sui.rpc.url",
                                                 "https://fullnode.testnet.sui.io:443").trim();
        this.packageId          = p.getProperty("sui.package.id", "").trim();
        this.identityRegistryId = p.getProperty("sui.identity.registry.id", "").trim();
        this.membershipCacheTtlMs = l(p, "trust.membership.cache.ttl.ms", 60_000);

        validate();
    }

    public static TrustConfig from(Properties p) {
        return new TrustConfig(p);
    }

    /** Sum of the eight weights. Should be 100 with the default config. */
    public double weightSum() {
        return wHeartbeat + wMalformed + wRate + wClock
             + wDeniedBurst + wHistorical + wInactive
             + wGarbage;
    }

    /** Tier index 0..N for a score, using the configured boundaries. */
    public int tierOf(double score) {
        int tier = 0;
        for (int i = 0; i < tierBoundaries.length; i++) {
            if (score >= tierBoundaries[i]) tier = i;
        }
        return tier;
    }

    /**
     * B9 — hysteresis dead-band. Production logs showed a node oscillating
     * across one boundary four times in a row because {@code tierOf} is a bare
     * {@code >=} comparison: an EMA hovering on the boundary alternates tiers
     * tick by tick, and every alternation was an on-chain write.
     *
     * <p>Returns true only when {@code score} has cleared the boundary it just
     * crossed by {@link #tierHysteresis} points. Moving up from {@code fromTier}
     * the relevant boundary is {@code tierBoundaries[fromTier + 1]}; moving down
     * it is {@code tierBoundaries[fromTier]} (the floor of the tier being left).
     *
     * @param score   the candidate (EMA) score
     * @param fromTier tier currently reflected on-chain
     * @param toTier   tier the raw score maps to
     */
    public boolean clearsTierBoundary(double score, int fromTier, int toTier) {
        if (toTier == fromTier) return false;
        double h = Math.max(0.0, tierHysteresis);
        if (toTier > fromTier) {
            int idx = fromTier + 1;
            if (idx >= tierBoundaries.length) return true; // already top tier
            return score >= tierBoundaries[idx] + h;
        }
        int idx = fromTier;
        if (idx <= 0) return true;                         // already bottom tier
        return score <= tierBoundaries[idx] - h;
    }

    private void validate() {
        double sum = weightSum();
        if (Math.abs(sum - 100.0) > 0.01) {
            throw new IllegalStateException(
                "Trust weights must sum to 100, got " + sum
                + ". Check trust.weight.* in sui.properties.");
        }
        if (emaAlpha < 0.0 || emaAlpha > 1.0) {
            throw new IllegalStateException("trust.ema.alpha must be in [0,1], got " + emaAlpha);
        }
        if (windowMs < tickPeriodMs) {
            throw new IllegalStateException("trust.window.ms must be >= trust.tick.period.ms");
        }
        if (tierHysteresis < 0.0) {
            throw new IllegalStateException("trust.tier.hysteresis must be >= 0");
        }
        if (tierConfirmTicks < 1) {
            throw new IllegalStateException("trust.tier.confirm.ticks must be >= 1");
        }
        if (maxDelta < 1 || maxDelta > 100) {
            throw new IllegalStateException("trust.max.delta must be in [1,100] (trust::MAX_DELTA is 15), got "
                    + maxDelta);
        }
        if (minWriteIntervalMs < MOVE_MIN_INTERVAL_MS) {
            throw new IllegalStateException("trust.min.write.interval.ms must be >= "
                    + MOVE_MIN_INTERVAL_MS + " (trust::MIN_INTERVAL_MS), got " + minWriteIntervalMs);
        }
        if (reattestPeriodMs <= 0 || reattestPeriodMs + minWriteIntervalMs >= MOVE_MS_PER_DAY) {
            throw new IllegalStateException("trust.reattest.period.ms must be > 0 and, plus"
                    + " trust.min.write.interval.ms, below one day (" + MOVE_MS_PER_DAY
                    + " ms) or on-chain decay accrues between re-attestations; got " + reattestPeriodMs);
        }
    }

    private static int[] parseTiers(String csv) {
        String[] parts = csv.split(",");
        int[] out = new int[parts.length];
        for (int i = 0; i < parts.length; i++) out[i] = Integer.parseInt(parts[i].trim());
        for (int i = 1; i < out.length; i++) {
            if (out[i] <= out[i - 1]) {
                throw new IllegalStateException("trust.tier.boundaries must be strictly ascending");
            }
        }
        return out;
    }

    private static double d(Properties p, String k, double def) {
        String v = p.getProperty(k);
        return (v == null || v.trim().isEmpty()) ? def : Double.parseDouble(v.trim());
    }
    private static long l(Properties p, String k, long def) {
        String v = p.getProperty(k);
        return (v == null || v.trim().isEmpty()) ? def : Long.parseLong(v.trim());
    }
    private static int i(Properties p, String k, int def) {
        String v = p.getProperty(k);
        return (v == null || v.trim().isEmpty()) ? def : Integer.parseInt(v.trim());
    }
}
