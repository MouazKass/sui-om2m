package org.eclipse.om2m.sui.trust;

import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Records raw behavioural events for every peer node and converts them, on
 * demand, into the seven direct-observation health values plus the single raw
 * attestation flag that make up a {@link NodeObservation}.
 *
 * <p>One instance lives on each CSE. The OM2M request path and the failover
 * manager call the {@code record*} hooks as events happen; the engine calls
 * {@link #snapshot} once per tick to read the current rolling-window health of
 * a given target.
 *
 * <p>All counters are kept in {@link RollingWindow} structures over the
 * configured window (default 60 s), so a snapshot always reflects "the last
 * 60 seconds of behaviour" regardless of how often it is taken.
 *
 * <p>The per-node resource baseline (used for the out-of-baseline signal) is
 * learned during a warm-up period: every resource a node touches in the first
 * {@code baselineWarmupMs} is added to its allowed set; after warm-up, requests
 * to resources outside that set count against the node.
 *
 * <p><b>B11/B12.</b> Three recorders were removed here:
 * {@code recordPtbResult} (it was fed the same {@code granted} boolean as
 * {@link #recordRequest}, so a single denied decision was counted twice — once
 * as a denied-burst event, once as a PTB abort; the signal is now carried
 * solely by the denied-decisions health), {@code setMqttMismatchFlag} (dead
 * code — zero call sites, so the signal was a constant) and
 * {@code setImpersonationFlag} (its only writer attributed a forged observation
 * to the impersonated victim rather than the forger — see B2 in
 * {@code TrustGossip.messageArrived}).
 */
public final class BehaviourObserver {

    private final TrustConfig cfg;
    private final String selfAddr;
    private final long startedAtMs;
    /** B6: this process's restart epoch, stamped on every observation we gossip. */
    private final long epoch;

    BehaviourObserver(TrustConfig cfg, String selfAddr, long epoch) {
        this.cfg = cfg;
        this.selfAddr = selfAddr;
        this.epoch = epoch;
        this.startedAtMs = System.currentTimeMillis();
    }

    /** Per-target rolling state. */
    private static final class Peer {
        final RollingWindow.Events heartbeats;
        final RollingWindow.Events requests;
        final RollingWindow.Events malformed;
        final RollingWindow.Events denied;
        final RollingWindow.Events outOfBaseline;
        final RollingWindow.Events inactiveHits;
        final RollingWindow.Values  clockDrift;

        final Set<String> baselineResources = ConcurrentHashMap.newKeySet();
        final AtomicLong lastRequestMs = new AtomicLong(0);

        // The one Group-3 raw flag this observer still asserts about the target.
        volatile boolean garbageFlag;

        Peer(long windowMs) {
            heartbeats    = new RollingWindow.Events(windowMs);
            requests      = new RollingWindow.Events(windowMs);
            malformed     = new RollingWindow.Events(windowMs);
            denied        = new RollingWindow.Events(windowMs);
            outOfBaseline = new RollingWindow.Events(windowMs);
            inactiveHits  = new RollingWindow.Events(windowMs);
            clockDrift    = new RollingWindow.Values(windowMs);
        }
    }

    private final Map<String, Peer> peers = new ConcurrentHashMap<>();

    private Peer peer(String addr) {
        return peers.computeIfAbsent(addr, a -> new Peer(cfg.windowMs));
    }

    private boolean inWarmup(long now) {
        return now - startedAtMs < cfg.baselineWarmupMs;
    }

    // ===================================================================
    // Recording hooks — called from the OM2M request path / failover loop.
    // ===================================================================

    /**
     * A heartbeat from {@code target} arrived (on time, by definition of the
     * caller). B9: the failover manager records this for <i>every</i>
     * middleware node that beats, not only the current parent — gating it on
     * the parent address pinned every other node's heartbeat health at 0 and
     * capped their trust score below the top tier.
     */
    public void recordHeartbeat(String target, long nowMs) {
        peer(target).heartbeats.add(nowMs);
    }

    /**
     * A request from {@code target} was processed.
     *
     * @param granted whether the access was ultimately granted
     * @param malformed whether the payload failed to parse / validate
     * @param resourceUri the oneM2M resource targeted (for the baseline signal)
     */
    public void recordRequest(String target, String resourceUri, boolean granted,
                       boolean malformed, long nowMs) {
        Peer p = peer(target);
        p.requests.add(nowMs);

        if (malformed) p.malformed.add(nowMs);
        // B12: the single home for "this node's access decisions were denied",
        // whether the denial came from the policy evaluation or from a PTB abort.
        if (!granted)  p.denied.add(nowMs);

        // Baseline learning / enforcement.
        if (resourceUri != null && !resourceUri.trim().isEmpty()) {
            if (inWarmup(nowMs)) {
                p.baselineResources.add(resourceUri);
            } else if (!p.baselineResources.contains(resourceUri)) {
                p.outOfBaseline.add(nowMs);
            }
        }

        // Inactive-period (off-hours) detection: a request after a long silence.
        long prev = p.lastRequestMs.getAndSet(nowMs);
        if (!inWarmup(nowMs) && prev > 0 && (nowMs - prev) > cfg.inactivityGapMs) {
            p.inactiveHits.add(nowMs);
        }
    }

    /** Observed clock drift (ms, absolute) for {@code target}. */
    public void recordClockDrift(String target, double driftMs, long nowMs) {
        peer(target).clockDrift.add(nowMs, Math.abs(driftMs));
    }

    /** Raise/clear this observer's garbage-payload flag for {@code target}. */
    public void setGarbageFlag(String target, boolean v)       { peer(target).garbageFlag = v; }

    // ===================================================================
    // Snapshot — called once per tick by the engine.
    // ===================================================================

    /** Set of peers this observer has any data about. */
    Set<String> observedTargets() {
        return peers.keySet();
    }

    /**
     * Compute the current health view of {@code target} as a
     * {@link NodeObservation}. Returns the engine-ready, normalised values.
     */
    NodeObservation snapshot(String target, long nowMs) {
        Peer p = peer(target);

        // ---- Group 1: protocol-level ----
        // Heartbeat: received vs expected over the window.
        double expected = Math.max(1.0, (double) cfg.windowMs / cfg.heartbeatPeriodMs);
        double hbHealth = clamp01(p.heartbeats.count(nowMs) / expected);

        int totalReq = p.requests.count(nowMs);
        double malHealth = (totalReq == 0)
            ? 1.0
            : clamp01(1.0 - (double) p.malformed.count(nowMs) / totalReq);

        double rateHealth = clamp01(1.0 - (double) totalReq / cfg.rateCeiling);

        double drift = p.clockDrift.max(nowMs, 0.0);
        double clkHealth = clamp01(1.0 - drift / cfg.maxClockDriftMs);

        // ---- Group 2: access-pattern ----
        // B12: denied decisions (policy DENY and PTB abort alike), 1 - d/20.
        double denHealth = clamp01(1.0 - (double) p.denied.count(nowMs) / cfg.deniedBurstThreshold);

        double histHealth = (totalReq == 0)
            ? 1.0
            : clamp01(1.0 - (double) p.outOfBaseline.count(nowMs) / totalReq);

        double inactHealth = (totalReq == 0)
            ? 1.0
            : clamp01(1.0 - (double) p.inactiveHits.count(nowMs) / totalReq);

        // ---- Group 3: raw flag (peer agreement applied later) ----
        return new NodeObservation(
            selfAddr, target, epoch, nowMs,
            hbHealth, malHealth, rateHealth, clkHealth,
            denHealth, histHealth, inactHealth,
            p.garbageFlag);
    }

    private static double clamp01(double v) {
        if (v < 0.0) return 0.0;
        if (v > 1.0) return 1.0;
        return v;
    }
}
