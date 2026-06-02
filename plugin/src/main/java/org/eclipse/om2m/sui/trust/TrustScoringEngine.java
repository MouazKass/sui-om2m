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

    private final TrustConfig cfg;
    private final NativePtbBuilder ptb;
    private final String selfAddr;
    private final String adminCapId;
    private final String clusterId;

    private final BehaviourObserver observer;
    private final TrustGossip gossip;

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
        this.ptb = ptb;
        this.selfAddr = selfAddr;
        this.adminCapId = adminCapId;
        this.clusterId = clusterId;
        this.observer = new BehaviourObserver(cfg, selfAddr);
        this.gossip = new TrustGossip(mqttBrokerUrl, clusterId, selfAddr, cfg.peerLivenessMs,
                                      keystorePath);
        this.gossip.attachObserver(this.observer);
    }

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

    private void scoreTarget(String target, long now) {
        List<NodeObservation> obs = new ArrayList<>(gossip.remoteObservationsOf(target, now));
        if (observer.observedTargets().contains(target)) {
            obs.add(observer.snapshot(target, now));
        }
        if (obs.isEmpty()) return;

        double local = aggregateAndScore(obs);

        TrustState st = states.computeIfAbsent(target, a -> new TrustState());
        if (!st.seeded) {
            long onChain = ptb.readTrustScore(target);
            st.seed(onChain >= 0 ? (double) onChain : 50.0);
        }
        st.updateEma(local, cfg.emaAlpha);

        int prevTier = cfg.tierOf(st.lastOnChain);
        int newTier  = cfg.tierOf(st.ema);
        if (newTier == prevTier) return;

        if (!amSubmitterFor(target, now)) {
            st.lastOnChain = clampScore(st.ema);
            return;
        }

        boolean ok = submitOnChain(target, st);
        if (ok) {
            LOG.info("[trust] {} crossed tier {}->{} (score {}) — submitted on-chain",
                     target, prevTier, newTier, Math.round(st.ema));
        }
    }

    private double aggregateAndScore(List<NodeObservation> obs) {
        int n = obs.size();
        double hb = 0, mal = 0, rate = 0, clk = 0, den = 0, abrt = 0, hist = 0, inact = 0;
        int impCount = 0, garCount = 0, mqttCount = 0;
        for (NodeObservation o : obs) {
            hb += o.heartbeatHealth; mal += o.malformedHealth; rate += o.rateHealth;
            clk += o.clockHealth; den += o.deniedBurstHealth; abrt += o.ptbAbortHealth;
            hist += o.historicalHealth; inact += o.inactiveHealth;
            if (o.impersonationFlag) impCount++;
            if (o.garbageFlag) garCount++;
            if (o.mqttMismatchFlag) mqttCount++;
        }
        hb /= n; mal /= n; rate /= n; clk /= n;
        den /= n; abrt /= n; hist /= n; inact /= n;

        double impHealth  = (impCount  >= cfg.peerAgreementThreshold) ? 0.0 : 1.0;
        double garHealth  = (garCount  >= cfg.peerAgreementThreshold) ? 0.0 : 1.0;
        double mqttHealth = (mqttCount >= cfg.peerAgreementThreshold) ? 0.0 : 1.0;

        double score =
              cfg.wHeartbeat     * hb
            + cfg.wMalformed     * mal
            + cfg.wRate          * rate
            + cfg.wClock         * clk
            + cfg.wDeniedBurst   * den
            + cfg.wPtbAbort      * abrt
            + cfg.wHistorical    * hist
            + cfg.wInactive      * inact
            + cfg.wImpersonation * impHealth
            + cfg.wGarbage       * garHealth
            + cfg.wMqttMismatch  * mqttHealth;
        return clampScore(score);
    }

    private boolean amSubmitterFor(String target, long now) {
        List<String> candidates = new ArrayList<>();
        for (String a : gossip.aliveNodes(now)) {
            if (!a.equalsIgnoreCase(target)) candidates.add(a.toLowerCase());
        }
        if (candidates.isEmpty()) return false;
        Collections.sort(candidates);
        return candidates.get(0).equalsIgnoreCase(selfAddr);
    }

    private boolean submitOnChain(String target, TrustState st) {
        long onChain = ptb.readTrustScore(target);
        if (onChain < 0) {
            LOG.warn("[trust] {} read-before-write failed; skipping this crossing", target);
            return false;
        }
        long want = Math.round(clampScore(st.ema));
        long delta = want - onChain;
        if (delta == 0) { st.lastOnChain = want; return true; }

        boolean increase = delta > 0;
        long mag = Math.abs(delta);

        NativePtbBuilder.Result r =
            ptb.submitTrustDelta(selfAddr, target, mag, increase, adminCapId);
        if (r.granted) {
            st.lastOnChain = want;
            LOG.debug("[trust] {} {} by {} ok digest={} {}ms",
                      target, increase ? "increase" : "decrease", mag, r.digest, r.elapsedMs);
            return true;
        }
        LOG.warn("[trust] {} {} by {} failed: {}",
                 target, increase ? "increase" : "decrease", mag, r.error);
        return false;
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
                TrustState st = new TrustState();
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
