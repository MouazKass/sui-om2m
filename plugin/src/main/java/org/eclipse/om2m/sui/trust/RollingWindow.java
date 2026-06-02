package org.eclipse.om2m.sui.trust;

import java.util.ArrayDeque;
import java.util.Deque;

/**
 * Thread-safe rolling windows over a fixed time horizon.
 *
 * <p>Two flavours are provided as nested classes:
 * <ul>
 *   <li>{@link Events} — counts discrete events (heartbeats received, requests,
 *       PTB aborts, denied requests, …) that occurred within the last
 *       {@code windowMs}.</li>
 *   <li>{@link Values} — keeps timestamped numeric samples (latency, clock
 *       drift) and exposes the mean / max within the window.</li>
 * </ul>
 *
 * <p>Both prune lazily on every access, so memory stays bounded by the event
 * rate over {@code windowMs}. All public methods synchronise on the instance,
 * which is sufficient here: the writers are the OM2M request / failover threads
 * (low frequency) and the single reader is the engine tick thread.
 */
final class RollingWindow {

    private RollingWindow() {}

    /** Counts events within a sliding time window. */
    static final class Events {
        private final long windowMs;
        private final Deque<Long> stamps = new ArrayDeque<>();

        Events(long windowMs) { this.windowMs = windowMs; }

        synchronized void add(long nowMs) {
            stamps.addLast(nowMs);
            prune(nowMs);
        }

        synchronized int count(long nowMs) {
            prune(nowMs);
            return stamps.size();
        }

        private void prune(long nowMs) {
            long cutoff = nowMs - windowMs;
            while (!stamps.isEmpty() && stamps.peekFirst() < cutoff) {
                stamps.removeFirst();
            }
        }
    }

    /** Keeps timestamped numeric samples within a sliding time window. */
    static final class Values {
        private final long windowMs;
        private final Deque<long[]> samples = new ArrayDeque<>(); // [tsMs, valueBits]

        Values(long windowMs) { this.windowMs = windowMs; }

        synchronized void add(long nowMs, double value) {
            samples.addLast(new long[]{ nowMs, Double.doubleToLongBits(value) });
            prune(nowMs);
        }

        /** Mean of samples in window, or {@code def} if none. */
        synchronized double mean(long nowMs, double def) {
            prune(nowMs);
            if (samples.isEmpty()) return def;
            double sum = 0.0;
            for (long[] s : samples) sum += Double.longBitsToDouble(s[1]);
            return sum / samples.size();
        }

        /** Max of samples in window, or {@code def} if none. */
        synchronized double max(long nowMs, double def) {
            prune(nowMs);
            if (samples.isEmpty()) return def;
            double m = Double.NEGATIVE_INFINITY;
            for (long[] s : samples) m = Math.max(m, Double.longBitsToDouble(s[1]));
            return m;
        }

        synchronized int count(long nowMs) {
            prune(nowMs);
            return samples.size();
        }

        private void prune(long nowMs) {
            long cutoff = nowMs - windowMs;
            while (!samples.isEmpty() && samples.peekFirst()[0] < cutoff) {
                samples.removeFirst();
            }
        }
    }
}
