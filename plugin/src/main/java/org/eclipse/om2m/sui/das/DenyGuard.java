package org.eclipse.om2m.sui.das;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.function.LongSupplier;

/**
 * F3: DENY bookkeeping for the Sui DAS.
 *
 * <p>Since the free pre-check, a DENY costs no gas, but every uncached
 * decision still costs a simulation round trip to the public GraphQL service
 * (and a token/registry read). This class bounds that work for originators
 * that keep asking for something they are not allowed:
 *
 * <ul>
 * <li><b>DENY cache.</b> A bounded LRU of {@code originator|resource|op} keys
 *     that the chain (or its simulation) just refused. A repeat inside
 *     {@code ttlMs} is denied locally with no network call. Only definite
 *     verdicts are cached, never transport errors, so an outage cannot
 *     outlive itself by a TTL. A cached DENY can only ever delay a GRANT by at
 *     most {@code ttlMs} after a policy change. It can never produce one.</li>
 * <li><b>Per-originator throttle.</b> An originator that collected
 *     {@code rateMax} verdict DENYs within the current {@code rateWindowMs}
 *     window is denied locally for the rest of that window, whatever it asks
 *     for. This bounds simulations from one originator spraying many distinct
 *     forbidden resources (which the per-key cache cannot catch). Originators
 *     under budget are unaffected; GRANTs never count.</li>
 * </ul>
 *
 * <p>Every DENY, whatever its source, is also written to the {@link DenyLog}.
 *
 * <p>Thread-safe; all state is behind this object's monitor and both maps are
 * size-bounded, so an attacker cannot grow memory by inventing originators or
 * resources.
 */
public final class DenyGuard {

    /** Where a DENY came from. */
    public enum Source {
        /** The free pre-check executed the exact transaction and it aborted. */
        SIMULATED,
        /** Submitted and aborted on-chain (paid). */
        CHAIN,
        /** Repeat of a recent verdict, served from the DENY cache. */
        CACHED,
        /** Originator over its DENY budget for this window. */
        THROTTLED,
        /** No originator-to-address or token mapping; never reaches the chain. */
        UNMAPPED,
        /** No verdict (pre-check unavailable, build/transport error); fail closed. */
        ERROR
    }

    private final long ttlMs;
    private final int rateMax;
    private final long rateWindowMs;
    private final LongSupplier clock;
    private final DenyLog log;

    private final LinkedHashMap<String, Long> denyCache;      // key -> expiry
    private final LinkedHashMap<String, long[]> windows;      // originator -> {windowStart, count}

    public DenyGuard(int cacheMax, long ttlMs, int rateMax, long rateWindowMs,
                     DenyLog log, LongSupplier clock) {
        this.ttlMs = ttlMs;
        this.rateMax = rateMax;
        this.rateWindowMs = rateWindowMs;
        this.clock = clock;
        this.log = log;
        final int cMax = Math.max(1, cacheMax);
        this.denyCache = new LinkedHashMap<String, Long>(16, 0.75f, true) {
            @Override protected boolean removeEldestEntry(Map.Entry<String, Long> e) { return size() > cMax; }
        };
        final int oMax = Math.max(1, cacheMax * 4);
        this.windows = new LinkedHashMap<String, long[]>(16, 0.75f, true) {
            @Override protected boolean removeEldestEntry(Map.Entry<String, long[]> e) { return size() > oMax; }
        };
    }

    public static String key(String originator, String resource, byte op) {
        return originator + "|" + resource + "|" + op;
    }

    /**
     * Decide locally, before any network call. Returns the local DENY source
     * ({@link Source#CACHED} or {@link Source#THROTTLED}), or {@code null} if
     * the request should go to the chain.
     */
    public synchronized Source preDecision(String originator, String key) {
        long now = clock.getAsLong();
        if (rateMax > 0) {
            long[] w = windows.get(originator);
            if (w != null && now - w[0] < rateWindowMs && w[1] >= rateMax) return Source.THROTTLED;
        }
        if (ttlMs > 0) {
            Long exp = denyCache.get(key);
            if (exp != null) {
                if (now < exp) return Source.CACHED;
                denyCache.remove(key);
            }
        }
        return null;
    }

    /**
     * Record a DENY: log it, and for chain verdicts (SIMULATED, CHAIN) cache
     * the key and charge the originator's window.
     */
    public void recordDeny(String originator, String address, String resource, byte op,
                           Source source, String reason) {
        long now = clock.getAsLong();
        if (source == Source.SIMULATED || source == Source.CHAIN) {
            synchronized (this) {
                if (ttlMs > 0) denyCache.put(key(originator, resource, op), now + ttlMs);
                if (rateMax > 0) {
                    long[] w = windows.get(originator);
                    if (w == null || now - w[0] >= rateWindowMs) {
                        windows.put(originator, new long[] { now, 1 });
                    } else {
                        w[1]++;
                    }
                }
            }
        }
        if (log != null) log.append(now, originator, address, resource, op, source.name(), reason);
    }

    /** For tests/monitoring. */
    synchronized int cachedKeys() { return denyCache.size(); }
}
