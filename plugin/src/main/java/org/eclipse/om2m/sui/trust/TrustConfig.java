package org.eclipse.om2m.sui.trust;

import java.util.Properties;

/**
 * Configuration for the trust scoring engine.
 *
 * <p>All weights, the EMA smoothing factor, the rolling-window length, the
 * observation period, the peer-agreement threshold, and the tier boundaries
 * are loaded from {@code sui.properties} so they can be tuned per deployment
 * without recompiling. Defaults match the values agreed in the design
 * discussion:
 *
 * <pre>
 *   Group 1 — Protocol level (45%)
 *     heartbeat            20
 *     malformed payload    10
 *     request-rate ceiling 10
 *     clock drift           5
 *
 *   Group 2 — Access pattern (35%)
 *     denied-request burst 15
 *     PTB abort rate       10
 *     out-of-baseline       7
 *     inactive-period       3
 *
 *   Group 3 — Peer attestation (20%)
 *     impersonation         8
 *     garbage payload       7
 *     MQTT mismatch         5
 * </pre>
 *
 * The eleven weights sum to 100, so a perfectly behaving node scores 100 and
 * a completely failed node scores 0.
 */
public final class TrustConfig {

    // === Group 1 — Protocol-level weights ===
    public final double wHeartbeat;
    public final double wMalformed;
    public final double wRate;
    public final double wClock;

    // === Group 2 — Access-pattern weights ===
    public final double wDeniedBurst;
    public final double wPtbAbort;
    public final double wHistorical;
    public final double wInactive;

    // === Group 3 — Peer-attestation weights ===
    public final double wImpersonation;
    public final double wGarbage;
    public final double wMqttMismatch;

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
    /** Minimum number of distinct peers that must agree before an
     *  attestation counts. Design: 2 (of 3 nodes). */
    public final int peerAgreementThreshold;
    /** A peer's gossip is "fresh" (node considered alive) if heard within
     *  this many ms. Used by the deterministic-submitter rule. */
    public final long peerLivenessMs;

    // === Detection thresholds (normalisers for the health functions) ===
    /** Request rate (requests within the window) at/above which rate_health = 0. */
    public final int rateCeiling;
    /** Clock drift (ms) at/above which clock_health = 0. */
    public final long maxClockDriftMs;
    /** Denied-request count within the window at/above which burst_health = 0. */
    public final int deniedBurstThreshold;
    /** Expected baseline PTB-abort fraction; aborts beyond this drive the score down. */
    public final double expectedAbortRate;
    /** Warm-up period (ms) during which the per-node resource baseline is learned. */
    public final long baselineWarmupMs;
    /** Silence gap (ms): a request after this much inactivity is "off-hours". */
    public final long inactivityGapMs;

    // === Tier boundaries (must mirror evolution.move) ===
    /** Sorted ascending. A score crossing any of these triggers an on-chain update. */
    public final int[] tierBoundaries;

    // === On-chain submission ===
    public final long gasBudget;

    // === EMA persistence ===
    public final String emaPersistPath;
    public final long   emaPersistPeriodMs;

    private TrustConfig(Properties p) {
        this.wHeartbeat     = d(p, "trust.weight.heartbeat",      20);
        this.wMalformed     = d(p, "trust.weight.malformed",      10);
        this.wRate          = d(p, "trust.weight.rate",           10);
        this.wClock         = d(p, "trust.weight.clock",           5);
        this.wDeniedBurst   = d(p, "trust.weight.denied_burst",   15);
        this.wPtbAbort      = d(p, "trust.weight.ptb_abort",      10);
        this.wHistorical    = d(p, "trust.weight.historical",      7);
        this.wInactive      = d(p, "trust.weight.inactive",        3);
        this.wImpersonation = d(p, "trust.weight.impersonation",   8);
        this.wGarbage       = d(p, "trust.weight.garbage",         7);
        this.wMqttMismatch  = d(p, "trust.weight.mqtt_mismatch",   5);

        this.emaAlpha       = d(p, "trust.ema.alpha",            0.30);

        this.tickPeriodMs       = l(p, "trust.tick.period.ms",      1_000);
        this.windowMs           = l(p, "trust.window.ms",         60_000);
        this.heartbeatPeriodMs  = l(p, "failover.heartbeat.period.ms", 5_000);

        this.peerAgreementThreshold = i(p, "trust.peer.agreement.threshold", 2);
        this.peerLivenessMs         = l(p, "trust.peer.liveness.ms", 30_000);

        this.rateCeiling          = i(p, "trust.rate.ceiling",        300);
        this.maxClockDriftMs      = l(p, "trust.clock.max.drift.ms", 5_000);
        this.deniedBurstThreshold = i(p, "trust.denied.burst.threshold", 20);
        this.expectedAbortRate    = d(p, "trust.ptb.expected.abort.rate", 0.05);
        this.baselineWarmupMs     = l(p, "trust.baseline.warmup.ms", 300_000);
        this.inactivityGapMs      = l(p, "trust.inactivity.gap.ms", 1_800_000);

        this.tierBoundaries = parseTiers(
            p.getProperty("trust.tier.boundaries", "0,25,50,75,90"));

        this.gasBudget = l(p, "sui.gas.budget", 20_000_000);
        this.emaPersistPath     = p.getProperty("trust.ema.persist.path",
                                                 "/tmp/trust-ema.properties").trim();
        this.emaPersistPeriodMs = l(p, "trust.ema.persist.period.ms", 30_000);

        validate();
    }

    public static TrustConfig from(Properties p) {
        return new TrustConfig(p);
    }

    /** Sum of the eleven weights. Should be 100 with the default config. */
    public double weightSum() {
        return wHeartbeat + wMalformed + wRate + wClock
             + wDeniedBurst + wPtbAbort + wHistorical + wInactive
             + wImpersonation + wGarbage + wMqttMismatch;
    }

    /** Tier index 0..N for a score, using the configured boundaries. */
    public int tierOf(double score) {
        int tier = 0;
        for (int i = 0; i < tierBoundaries.length; i++) {
            if (score >= tierBoundaries[i]) tier = i;
        }
        return tier;
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
