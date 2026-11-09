package org.eclipse.om2m.sui.trust;

import org.eclipse.om2m.sui.sdk.NativePtbBuilder;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

public final class TrustScoringEngine {

    private static final Slf4jStyleLog LOG = Slf4jStyleLog.getLogger(TrustScoringEngine.class);

    /** trust.move abort: a single write's delta exceeds MAX_DELTA. */
    static final int E_DELTA_TOO_LARGE = 6;
    /** trust.move abort: write inside MIN_INTERVAL_MS of the entry's last write. */
    static final int E_RATE_LIMITED = 7;
    /** Ceiling for the exponential backoff after a non-rate-limit write failure. */
    static final long MAX_FAILURE_BACKOFF_MS = 3_600_000L;

    // =================================================================
    // Seams. Production wires these to NativePtbBuilder / TrustGossip /
    // BehaviourObserver; unit tests supply hermetic fakes.
    // =================================================================

    /** The two on-chain operations the engine performs. */
    interface TrustChain {
        /** Decayed on-chain score via {@code trust::score_of}, or -1 on failure. */
        long readTrustScore(String target);
        /** One {@code increase_guarded}/{@code decrease_guarded} write. */
        WriteResult submitTrustDelta(String submitter, String target, long magnitude,
                                     boolean increase, String adminCapId);
    }

    /** Outcome of a write; {@code error} carries the raw (MoveAbort) error text. */
    static final class WriteResult {
        final boolean ok;
        final String digest;
        final long elapsedMs;
        final String error;
        WriteResult(boolean ok, String digest, long elapsedMs, String error) {
            this.ok = ok; this.digest = digest; this.elapsedMs = elapsedMs; this.error = error;
        }
    }

    /** What the engine knows about the cluster: observations and liveness. */
    interface PeerView {
        /** Fresh observations of {@code target} (remote gossip + local snapshot). */
        List<NodeObservation> observationsOf(String target, long nowMs);
        /** Registered nodes currently alive (self included). */
        Set<String> aliveNodes(long nowMs);
        /** Is {@code addr} a registered member that gossiped recently? */
        boolean isAlive(String addr, long nowMs);
    }

    private static final class PtbChain implements TrustChain {
        private final NativePtbBuilder ptb;
        PtbChain(NativePtbBuilder ptb) { this.ptb = ptb; }
        @Override public long readTrustScore(String target) { return ptb.readTrustScore(target); }
        @Override public WriteResult submitTrustDelta(String submitter, String target, long magnitude,
                                                      boolean increase, String adminCapId) {
            NativePtbBuilder.Result r =
                ptb.submitTrustDelta(submitter, target, magnitude, increase, adminCapId);
            return new WriteResult(r.granted, r.digest, r.elapsedMs, r.error);
        }
    }

    private final TrustConfig cfg;
    private final TrustChain chain;
    private final PeerView view;
    private final String selfAddr;
    private final String adminCapId;
    private final String clusterId;

    private final BehaviourObserver observer;
    private final TrustGossip gossip;
    private final MemberRegistry members;
    /** B6: this process's observer restart epoch. */
    private final long epoch;

    private final Map<String, TrustState> states = new ConcurrentHashMap<>();

    private final ScheduledExecutorService scheduler =
        Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "sui-trust-engine");
            t.setDaemon(true);
            return t;
        });
    private ScheduledFuture<?> tickTask;

    // === Static accessor so the request path + failover loop can find the
    //     active observer without constructor-injection plumbing. ===
    private static volatile TrustScoringEngine ACTIVE;
    public static BehaviourObserver activeObserver() {
        TrustScoringEngine e = ACTIVE;
        return (e == null) ? null : e.observer;
    }
    private ScheduledFuture<?> persistTask;

    public TrustScoringEngine(
        TrustConfig cfg, NativePtbBuilder ptb,
        String selfAddr, String adminCapId,
        String mqttBrokerUrl, String clusterId,
        String keystorePath
    ) {
        this.cfg = cfg;
        this.chain = new PtbChain(ptb);
        this.selfAddr = selfAddr;
        this.adminCapId = adminCapId;
        this.clusterId = clusterId;
        // B6: one restart epoch per process, stamped on every observation we
        // gossip so a backwards clock jump across a restart cannot get us
        // permanently classified as a replayer.
        this.epoch = ObserverEpoch.nextEpoch(cfg.epochPersistPath);
        this.observer = new BehaviourObserver(cfg, selfAddr, this.epoch);
        // B10: observers must be registered cluster members, not merely holders
        // of a self-consistent keypair.
        this.members = new IdentityRegistryMembers(
            cfg.rpcUrl, cfg.packageId, cfg.identityRegistryId, selfAddr,
            cfg.membershipCacheTtlMs);
        this.gossip = new TrustGossip(mqttBrokerUrl, clusterId, selfAddr, cfg.peerLivenessMs,
                                      keystorePath, this.members);
        this.gossip.attachObserver(this.observer);
        this.view = new GossipView();
    }

    /**
     * Test seam: an engine with no MQTT, no observer and no filesystem.
     * Drive it with {@link #scoreTarget(String, long)}.
     */
    TrustScoringEngine(TrustConfig cfg, TrustChain chain, PeerView view,
                       String selfAddr, String adminCapId) {
        this.cfg = cfg;
        this.chain = chain;
        this.view = view;
        this.selfAddr = selfAddr;
        this.adminCapId = adminCapId;
        this.clusterId = "test";
        this.epoch = 0L;
        this.observer = null;
        this.members = null;
        this.gossip = null;
    }

    /** Production view: remote gossip plus this node's own direct observation. */
    private final class GossipView implements PeerView {
        @Override public List<NodeObservation> observationsOf(String target, long now) {
            List<NodeObservation> obs = new ArrayList<>(gossip.remoteObservationsOf(target, now));
            if (observer.observedTargets().contains(target)) {
                obs.add(observer.snapshot(target, now));
            }
            return obs;
        }
        @Override public Set<String> aliveNodes(long now) { return gossip.aliveNodes(now); }
        @Override public boolean isAlive(String addr, long now) { return gossip.isAlive(addr, now); }
    }

    /** Test access to per-target state. */
    TrustState stateOf(String target) { return states.get(target); }

    public BehaviourObserver observer() { return observer; }

    public void start() {
        ACTIVE = this;
        loadEma();
        gossip.start();
        tickTask = scheduler.scheduleAtFixedRate(
            this::tickSafe, cfg.tickPeriodMs, cfg.tickPeriodMs, TimeUnit.MILLISECONDS);
        persistTask = scheduler.scheduleAtFixedRate(
            this::saveEmaSafe, cfg.emaPersistPeriodMs, cfg.emaPersistPeriodMs, TimeUnit.MILLISECONDS);
        LOG.info("[trust] engine started. self={} tick={}ms window={}ms alpha={} adminCap={}",
                 selfAddr, cfg.tickPeriodMs, cfg.windowMs, cfg.emaAlpha, adminCapId);
    }

    public void stop() {
        ACTIVE = null;
        if (tickTask != null) tickTask.cancel(false);
        if (persistTask != null) persistTask.cancel(false);
        saveEmaSafe();
        scheduler.shutdownNow();
        gossip.stop();
    }

    private void tickSafe() {
        try { tick(); }
        catch (Throwable t) { LOG.warn("[trust] tick error: {}", t.getMessage()); }
    }

    private void tick() {
        long now = System.currentTimeMillis();
        List<NodeObservation> mine = new ArrayList<>();
        for (String target : observer.observedTargets()) {
            // B4: do NOT publish self-observations. They used to be gossiped on
            // the theory that peers "may corroborate" them, but a node's own
            // view of itself is input it fully controls, and it landed in the
            // aggregate every peer computed about it. Only peer-attested
            // observations are published, and only peers attest to peers.
            if (target.equalsIgnoreCase(selfAddr)) continue;
            mine.add(observer.snapshot(target, now));
        }
        gossip.publish(mine);

        Set<String> targets = new java.util.HashSet<>();
        for (NodeObservation o : mine) targets.add(o.targetAddr);
        for (String alive : gossip.aliveNodes(now)) {
            if (!alive.equalsIgnoreCase(selfAddr)) targets.add(alive);
        }
        for (String target : targets) {
            if (target.equalsIgnoreCase(selfAddr)) continue;
            scoreTarget(target, now);
        }
    }

    void scoreTarget(String target, long now) {
        List<NodeObservation> obs = view.observationsOf(target, now);
        if (obs.isEmpty()) return;

        double local = aggregateAndScore(obs);

        TrustState st = states.computeIfAbsent(target, a -> new TrustState(now));
        if (!st.seeded) {
            long onChain = chain.readTrustScore(target);
            if (onChain < 0) {
                // Fail-closed (assume-breach): an unverifiable node is NOT seeded
                // at neutral. Skip scoring it this tick and retry once the chain
                // read succeeds. Prevents a bad actor from resetting to neutral.
                LOG.warn("[trust] on-chain read failed for {}; skipping (fail-closed)", target);
                return;
            }
            st.seed((double) onChain);
        }
        st.updateEma(local, cfg.emaAlpha);

        boolean crossing = crossingConfirmed(target, st);
        boolean submitter = amSubmitterFor(target, now);

        if (!submitter) {
            // A non-submitter never writes. If it believes a crossing is due it
            // checks the chain instead (B5b).
            if (crossing) confirmViaChain(target, st);
            return;
        }

        // Re-attestation (decay re-anchoring). trust::score_of loses 1 point
        // per FULL day since the entry's last write, and a crossing-only writer
        // never writes a stable node, so a healthy node used to decay to 0.
        // The submitter therefore re-writes every live target whose decay
        // clock it has not re-anchored within cfg.reattestPeriodMs (< 1 day).
        // Only FRESH targets qualify: a silent/offline node must be allowed to
        // decay (TR4) - re-attesting it from stale state would keep a dead node
        // trusted forever.
        boolean fresh = isFresh(target, obs, now);
        boolean reattestDue = fresh && (now - st.lastAnchorMs >= cfg.reattestPeriodMs);
        if (!crossing && !reattestDue) return;

        // TR4: never raise a stale target. (Checked before the chain read so a
        // dead node with a pending upward crossing costs nothing per tick.)
        if (!fresh && st.ema > st.lastOnChain) {
            LOG.debug("[trust] {} not fresh; refusing upward write (TR4)", target);
            return;
        }

        // A12 pacing: one write per target per cfg.minWriteIntervalMs, plus any
        // backoff from a failed write. Checked before the chain read so a
        // paced target costs no RPC either.
        if (!writeWindowOpen(st, now)) return;

        syncOnChain(target, st, now, crossing, reattestDue, fresh);
    }

    /**
     * B9 hysteresis: true iff the EMA has left the on-chain tier, cleared the
     * dead-band, and held the new tier for cfg.tierConfirmTicks ticks.
     */
    private boolean crossingConfirmed(String target, TrustState st) {
        int prevTier = cfg.tierOf(st.lastOnChain);
        int newTier  = cfg.tierOf(st.ema);
        if (newTier == prevTier) {
            st.clearPendingTier();
            return false;
        }

        // B9 hysteresis, part 1 — dead-band. tierOf() is a bare >= test, so an
        // EMA sitting on a boundary alternates tiers from tick to tick and each
        // alternation was an on-chain write (production logs: one node flapped
        // across a boundary 4 times). Require the score to clear the boundary it
        // just crossed by cfg.tierHysteresis points.
        if (!cfg.clearsTierBoundary(st.ema, prevTier, newTier)) {
            if (st.pendingTier != -1) {
                LOG.debug("[trust] {} score {} inside tier dead-band ({}->{}); crossing dropped",
                          target, String.format(java.util.Locale.ROOT, "%.2f", st.ema),
                          prevTier, newTier);
            }
            st.clearPendingTier();
            return false;
        }

        // B9 hysteresis, part 2 — persistence. The new tier must hold for
        // cfg.tierConfirmTicks consecutive ticks before we act on it.
        int held = st.observeCandidateTier(newTier);
        if (held < cfg.tierConfirmTicks) {
            LOG.debug("[trust] {} tier {}->{} pending confirmation ({}/{} ticks)",
                      target, prevTier, newTier, held, cfg.tierConfirmTicks);
            return false;
        }
        return true;
    }

    /**
     * B5b: we are NOT the submitter for this target, so somebody else is
     * supposed to write the crossing. The old code optimistically stamped
     * lastOnChain with our LOCAL EMA estimate, which made prevTier == newTier
     * on the next tick and permanently stopped the retry — so if the real
     * submitter's write failed (or it never believed it was the submitter,
     * which the local-view election allows), the crossing was silently lost
     * forever.
     *
     * <p>Read what is ACTUALLY on-chain instead. If the write landed,
     * lastOnChain now matches and we go quiet; if it did not, the crossing
     * stays pending and we re-evaluate on the next tick. With capped writes
     * the submitter converges over several steps; each step is observed here.
     */
    private void confirmViaChain(String target, TrustState st) {
        int prevTier = cfg.tierOf(st.lastOnChain);
        int newTier  = cfg.tierOf(st.ema);
        long onChain = chain.readTrustScore(target);
        if (onChain < 0) {
            LOG.warn("[trust] {} not submitter and on-chain read failed;"
                   + " keeping crossing pending (will retry)", target);
            return;
        }
        st.lastOnChain = clampScore((double) onChain);
        int confirmedTier = cfg.tierOf(st.lastOnChain);
        if (confirmedTier == newTier) {
            LOG.debug("[trust] {} tier {}->{} confirmed on-chain by the submitter (score {})",
                      target, prevTier, newTier, onChain);
            st.clearPendingTier();
        } else {
            LOG.info("[trust] {} tier {}->{} NOT yet on-chain (chain score {} = tier {});"
                   + " retrying next tick", target, prevTier, newTier, onChain, confirmedTier);
        }
    }

    /**
     * "Fresh" reuses the code's existing liveness notion: the target is a
     * registered member whose own gossip is within peerLivenessMs
     * ({@link TrustGossip#isAlive}), AND at least one admitted observation
     * actually heard its heartbeat (remote observations are already filtered
     * to peerLivenessMs; the local snapshot covers the rolling window). A node
     * that stopped beating and gossiping is not fresh, even though this
     * node's local snapshot of it persists with default 1.0 values for the
     * request-derived signals (which is why its EMA bottoms out around 75
     * rather than 0, and why re-attesting it would pin it there forever).
     */
    private boolean isFresh(String target, List<NodeObservation> obs, long now) {
        if (!view.isAlive(target, now)) return false;
        for (NodeObservation o : obs) {
            if (o.heartbeatHealth > 0.0) return true;
        }
        return false;
    }

    private boolean writeWindowOpen(TrustState st, long now) {
        return now - st.lastWriteMs >= cfg.minWriteIntervalMs && now >= st.backoffUntilMs;
    }

    /**
     * Aggregate every admitted observer's view of one target into a single
     * 0..100 score.
     *
     * <p><b>B3 — median, not mean.</b> The value signals used to be combined
     * with an arithmetic mean ({@code /= n}). A mean has no breakdown point: a
     * single Byzantine observer reporting 0.0 (or 1.0) drags the aggregate by
     * {@code 1/n} of the full range, and a sufficiently extreme report can move
     * the target across a tier boundary on its own. The median of the same
     * samples is unaffected by any minority of arbitrary values.
     *
     * <p><b>B3 — derived agreement threshold.</b> The flag threshold was the
     * fixed config constant {@code trust.peer.agreement.threshold} (default 2),
     * which bears no relation to how many observers actually reported: with 2
     * live observers it meant unanimity, with 9 it let 2 observers out of 9 zero
     * a signal, and it carried no Byzantine-fault bound at all. It is now
     * {@code k = floor((n-1)/2) + 1}, i.e. a strict majority of the n admitted
     * observers — the standard bound for tolerating up to
     * {@code floor((n-1)/2)} faulty participants. This is only meaningful
     * because B10 now bounds who may be an observer at all; without the
     * membership check an attacker could mint keypairs to inflate n.
     */
    private double aggregateAndScore(List<NodeObservation> obs) {
        int n = obs.size();
        if (n == 0) return clampScore(0.0);

        double hb    = median(obs, Signal.HEARTBEAT);
        double mal   = median(obs, Signal.MALFORMED);
        double rate  = median(obs, Signal.RATE);
        double clk   = median(obs, Signal.CLOCK);
        double den   = median(obs, Signal.DENIED);
        double hist  = median(obs, Signal.HISTORICAL);
        double inact = median(obs, Signal.INACTIVE);

        int garCount = 0;
        for (NodeObservation o : obs) {
            if (o.garbageFlag) garCount++;
        }
        // k = floor((n-1)/2) + 1  — strict majority of the n observers.
        int k = agreementThreshold(n);
        double garHealth = (garCount >= k) ? 0.0 : 1.0;

        double score =
              cfg.wHeartbeat     * hb
            + cfg.wMalformed     * mal
            + cfg.wRate          * rate
            + cfg.wClock         * clk
            + cfg.wDeniedBurst   * den
            + cfg.wHistorical    * hist
            + cfg.wInactive      * inact
            + cfg.wGarbage       * garHealth;
        return clampScore(score);
    }

    /**
     * B3: peer-agreement threshold for n observers, k = floor((n-1)/2) + 1.
     * Tolerates up to floor((n-1)/2) Byzantine observers.
     */
    static int agreementThreshold(int n) {
        if (n <= 0) return 1;
        return ((n - 1) / 2) + 1;
    }

    /** The per-observation value signals the median is taken over. */
    enum Signal { HEARTBEAT, MALFORMED, RATE, CLOCK, DENIED, HISTORICAL, INACTIVE }

    private static double valueOf(NodeObservation o, Signal s) {
        switch (s) {
            case HEARTBEAT:  return o.heartbeatHealth;
            case MALFORMED:  return o.malformedHealth;
            case RATE:       return o.rateHealth;
            case CLOCK:      return o.clockHealth;
            case DENIED:     return o.deniedBurstHealth;
            case HISTORICAL: return o.historicalHealth;
            case INACTIVE:   return o.inactiveHealth;
            default:         return 0.0;
        }
    }

    /**
     * Median of one signal across all observations. Even counts use the mean of
     * the two central samples (the textbook definition); with n == 2 that
     * degenerates to the mean, which is unavoidable — two observers cannot
     * outvote each other.
     */
    static double median(List<NodeObservation> obs, Signal s) {
        int n = obs.size();
        double[] v = new double[n];
        for (int i = 0; i < n; i++) v[i] = valueOf(obs.get(i), s);
        java.util.Arrays.sort(v);
        int mid = n / 2;
        return ((n & 1) == 1) ? v[mid] : 0.5 * (v[mid - 1] + v[mid]);
    }

    /**
     * Deterministic submitter rule: lowest address among the alive nodes other
     * than the target.
     *
     * <p>Known limitation (B5, deliberately NOT fixed by bolting leader
     * election on here): "alive" is each node's LOCAL view, so two nodes can
     * briefly disagree and both submit, or neither does. B5b removes the
     * harmful half of that — a non-submitter no longer assumes the write
     * happened (see scoreTarget), so a dropped crossing is retried until it
     * really lands. The duplicate-submission half is made harmless on-chain by
     * the MAX_DELTA / MIN_INTERVAL_MS rate limit in the Move trust module,
     * which aborts the second write of the same crossing instead of
     * double-applying the delta. {@link #syncOnChain} treats that abort
     * (E_RATE_LIMITED, 7) as "back off one interval", not as a failure.
     */
    private boolean amSubmitterFor(String target, long now) {
        List<String> candidates = new ArrayList<>();
        for (String a : view.aliveNodes(now)) {
            if (!a.equalsIgnoreCase(target)) candidates.add(a.toLowerCase());
        }
        if (candidates.isEmpty()) return false;
        Collections.sort(candidates);
        return candidates.get(0).equalsIgnoreCase(selfAddr);
    }

    /**
     * Read the (decayed) on-chain score and write at most ONE capped step
     * toward the target score.
     *
     * <ul>
     *   <li>Each write carries at most {@code cfg.maxDelta} (trust::MAX_DELTA);
     *       larger moves converge over several writes, one per
     *       {@code cfg.minWriteIntervalMs}, until the on-chain tier matches.</li>
     *   <li>{@code lastOnChain} is set to the value actually produced on-chain
     *       ({@code onChain +/- mag}, clamped), not to the EMA.</li>
     *   <li>A due re-attestation always writes - with delta 0 if the score is
     *       already right - purely to re-anchor {@code last_update_ms}. It never
     *       crosses a tier on its own: outside a B9-confirmed crossing the
     *       target is clamped into the on-chain tier.</li>
     *   <li>Abort 7 (E_RATE_LIMITED: another writer got in first) and abort 6
     *       (E_DELTA_TOO_LARGE: config disagrees with Move) back off one
     *       interval and retry; abort 6 also halves this target's cap. Any
     *       other failure backs off exponentially, up to 1 h.</li>
     * </ul>
     */
    private void syncOnChain(String target, TrustState st, long now,
                             boolean crossing, boolean reattestDue, boolean fresh) {
        long onChain = chain.readTrustScore(target);
        if (onChain < 0) {
            LOG.warn("[trust] {} read-before-write failed; skipping this write", target);
            return;
        }
        st.lastOnChain = clampScore((double) onChain);

        int chainTier = cfg.tierOf(onChain);
        int emaTier   = cfg.tierOf(st.ema);
        boolean crossingOpen = crossing && chainTier != emaTier;
        if (crossing && !crossingOpen) {
            // Already in the target tier (another writer, or decay).
            LOG.debug("[trust] {} tier {} already on-chain (score {})", target, emaTier, onChain);
            st.clearPendingTier();
        }
        if (!crossingOpen && !reattestDue) return;

        long want = Math.round(clampScore(st.ema));
        if (!crossingOpen) want = clampToTier(want, chainTier);
        if (!fresh && want > onChain) return;                 // TR4: never raise a stale target

        long delta = want - onChain;
        long cap = (st.learnedDeltaCap > 0) ? Math.min(st.learnedDeltaCap, cfg.maxDelta) : cfg.maxDelta;
        long mag = Math.min(Math.abs(delta), cap);
        boolean increase = delta >= 0;   // a 0-delta re-anchor is sent as increase(0)
        String kind = increase ? "increase" : "decrease";

        st.lastWriteMs = now;
        WriteResult r = chain.submitTrustDelta(selfAddr, target, mag, increase, adminCapId);
        if (r.ok) {
            st.lastOnChain = clampScore((double) (increase ? onChain + mag : onChain - mag));
            st.lastAnchorMs = now;
            st.consecutiveFailures = 0;
            st.backoffUntilMs = 0L;
            if (cfg.tierOf(st.lastOnChain) == emaTier) st.clearPendingTier();
            if (crossingOpen) {
                LOG.info("[trust] {} tier {}->{}: {} by {} (chain {} -> {}, target {}) digest={} {}ms",
                         target, chainTier, emaTier, kind, mag, onChain,
                         Math.round(st.lastOnChain), want, r.digest, r.elapsedMs);
            } else {
                LOG.debug("[trust] {} re-attested: {} by {} (chain {} -> {}) digest={}",
                          target, kind, mag, onChain, Math.round(st.lastOnChain), r.digest);
            }
            return;
        }

        int code = moveAbortCode(r.error);
        if (code == E_RATE_LIMITED) {
            st.backoffUntilMs = now + cfg.minWriteIntervalMs;
            LOG.info("[trust] {} {} by {} rate-limited on-chain (abort 7; another writer?);"
                   + " backing off {}ms", target, kind, mag, cfg.minWriteIntervalMs);
        } else if (code == E_DELTA_TOO_LARGE) {
            st.learnedDeltaCap = Math.max(1L, mag / 2);
            st.backoffUntilMs = now + cfg.minWriteIntervalMs;
            LOG.warn("[trust] {} {} by {} exceeds on-chain MAX_DELTA (abort 6): trust.max.delta={}"
                   + " disagrees with trust.move; capping this target at {} and backing off",
                     target, kind, mag, cfg.maxDelta, st.learnedDeltaCap);
        } else {
            st.consecutiveFailures++;
            long backoff = cfg.minWriteIntervalMs << Math.min(st.consecutiveFailures - 1, 16);
            if (backoff <= 0 || backoff > MAX_FAILURE_BACKOFF_MS) {
                backoff = Math.max(MAX_FAILURE_BACKOFF_MS, cfg.minWriteIntervalMs);
            }
            st.backoffUntilMs = now + backoff;
            LOG.warn("[trust] {} {} by {} failed ({} in a row; backing off {}ms): {}",
                     target, kind, mag, st.consecutiveFailures, backoff, r.error);
        }
    }

    /** Clamp {@code v} into the score range of {@code tier}. */
    private long clampToTier(long v, int tier) {
        int[] b = cfg.tierBoundaries;
        long lo = (tier <= 0) ? 0L : b[tier];
        long hi = (tier + 1 < b.length) ? b[tier + 1] - 1L : 100L;
        return Math.max(lo, Math.min(hi, v));
    }

    private static final java.util.regex.Pattern ABORT_MODULE =
        java.util.regex.Pattern.compile("name:\\s*Identifier\\(\"(\\w+)\"\\)");
    private static final java.util.regex.Pattern ABORT_CODE =
        java.util.regex.Pattern.compile("\\},\\s*(\\d+)\\)");

    /**
     * Abort code of a {@code trust}-module MoveAbort in a write error, or -1.
     * Same format and regexes as {@code das.AbortDecoder}: SuiRpcClient renders
     * execution errors as {@code MoveAbort(MoveLocation { module: ModuleId {
     * address: P, name: Identifier("trust") }, ... }, CODE) -- msg}.
     */
    static int moveAbortCode(String err) {
        if (err == null || !err.contains("MoveAbort")) return -1;
        java.util.regex.Matcher mod = ABORT_MODULE.matcher(err);
        java.util.regex.Matcher code = ABORT_CODE.matcher(err);
        if (!mod.find() || !"trust".equals(mod.group(1)) || !code.find()) return -1;
        try { return Integer.parseInt(code.group(1)); } catch (NumberFormatException e) { return -1; }
    }

    private static double clampScore(double v) {
        if (v < 0.0) return 0.0;
        if (v > 100.0) return 100.0;
        return v;
    }

    private void saveEmaSafe() {
        try { saveEma(); }
        catch (Throwable t) { LOG.debug("[trust] EMA save failed: {}", t.getMessage()); }
    }

    private void saveEma() throws IOException {
        Properties p = new Properties();
        p.setProperty("_savedAtMs", Long.toString(System.currentTimeMillis()));
        for (Map.Entry<String, TrustState> e : states.entrySet()) {
            TrustState st = e.getValue();
            if (!st.seeded) continue;
            p.setProperty(e.getKey().toLowerCase(), st.ema + "," + st.lastOnChain);
        }
        Path path = Paths.get(cfg.emaPersistPath);
        Path tmp = Paths.get(cfg.emaPersistPath + ".tmp");
        try (OutputStream os = Files.newOutputStream(tmp)) {
            p.store(os, "sui-trust EMA state (cluster=" + clusterId + ")");
        }
        Files.move(tmp, path, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
    }

    private void loadEma() {
        Path path = Paths.get(cfg.emaPersistPath);
        if (!Files.exists(path)) {
            LOG.info("[trust] no persisted EMA at {} — cold start", cfg.emaPersistPath);
            return;
        }
        try (InputStream in = Files.newInputStream(path)) {
            Properties p = new Properties();
            p.load(in);
            long savedAt = parseLong(p.getProperty("_savedAtMs"), 0L);
            long age = System.currentTimeMillis() - savedAt;
            long maxAge = Math.max(cfg.windowMs, cfg.peerLivenessMs * 4);
            if (savedAt == 0L || age > maxAge) {
                LOG.info("[trust] persisted EMA stale (age={}ms > {}ms) — cold start", age, maxAge);
                return;
            }
            int loaded = 0;
            for (String key : p.stringPropertyNames()) {
                if (key.startsWith("_")) continue;
                String[] parts = p.getProperty(key).split(",");
                if (parts.length != 2) continue;
                TrustState st = new TrustState(System.currentTimeMillis());
                st.seed(clampScore(parseDouble(parts[1], 50.0)));
                st.ema = clampScore(parseDouble(parts[0], st.lastOnChain));
                states.put(key.toLowerCase(), st);
                loaded++;
            }
            LOG.info("[trust] restored EMA for {} target(s) (age={}ms)", loaded, age);
        } catch (Exception e) {
            LOG.warn("[trust] EMA load failed ({}); cold start", e.getMessage());
        }
    }

    private static long parseLong(String s, long def) {
        try { return s == null ? def : Long.parseLong(s.trim()); } catch (Exception e) { return def; }
    }
    private static double parseDouble(String s, double def) {
        try { return s == null ? def : Double.parseDouble(s.trim()); } catch (Exception e) { return def; }
    }
}
