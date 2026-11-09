package org.eclipse.om2m.sui.trust;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.Properties;

/**
 * B6 — the per-observer restart epoch used as the high-order component of the
 * gossip anti-replay ordinal {@code (epoch, producedAtMs)}.
 *
 * <p>Problem it solves: v1 gossip ordered observations purely by
 * {@code producedAtMs}. If a node's wall clock went backwards across a restart
 * (NTP correction, RTC-less Raspberry Pi booting before network time), every
 * observation it produced afterwards looked older than the one its peers had
 * already stored, so it was rejected as a replay <i>permanently</i> — until the
 * clock caught back up. The node's trust telemetry silently disappeared from
 * the cluster.
 *
 * <p>Fix: a monotonic counter bumped once per process start and shipped in
 * every observation. A higher epoch means "the observer restarted", which is
 * always accepted regardless of the timestamp; within one epoch the old strict
 * {@code producedAtMs} monotonicity still applies.
 *
 * <p>Persistence reuses the same local-state convention the engine already has
 * for the EMA snapshot (a {@link Properties} file written tmp-then-move), so no
 * new storage mechanism is introduced. The file lives beside the EMA file by
 * default ({@code <trust.ema.persist.path>.epoch}).
 *
 * <p>The next epoch is {@code max(stored + 1, unixSeconds)}. The {@code +1}
 * term guarantees strict monotonicity in the normal case; the {@code unixSeconds}
 * floor keeps the sequence increasing even if the state file is lost (a wiped
 * {@code /tmp}, a fresh container), which would otherwise reset the counter and
 * re-introduce exactly the permanent-rejection failure this class exists to
 * remove.
 */
final class ObserverEpoch {

    private static final Slf4jStyleLog LOG = Slf4jStyleLog.getLogger(ObserverEpoch.class);
    private static final String KEY = "epoch";

    private ObserverEpoch() {}

    /**
     * Read the persisted epoch, bump it, persist the new value and return it.
     * Called exactly once per process (from the engine constructor).
     *
     * @param persistPath file holding the counter; may not exist yet
     * @return the epoch this process must stamp on every observation it gossips
     */
    static long nextEpoch(String persistPath) {
        long stored = read(persistPath);
        long floor = System.currentTimeMillis() / 1000L;
        long next = Math.max(stored + 1L, floor);
        write(persistPath, next);
        LOG.info("[trust] B6 observer epoch {} -> {} (persist={})", stored, next, persistPath);
        return next;
    }

    private static long read(String persistPath) {
        try {
            Path p = Paths.get(persistPath);
            if (!Files.exists(p)) return 0L;
            Properties props = new Properties();
            try (InputStream in = Files.newInputStream(p)) {
                props.load(in);
            }
            String v = props.getProperty(KEY);
            return (v == null) ? 0L : Long.parseLong(v.trim());
        } catch (Exception e) {
            LOG.warn("[trust] epoch read failed ({}); falling back to clock floor", e.getMessage());
            return 0L;
        }
    }

    private static void write(String persistPath, long epoch) {
        try {
            Path p = Paths.get(persistPath);
            Path tmp = Paths.get(persistPath + ".tmp");
            if (p.getParent() != null) Files.createDirectories(p.getParent());
            Properties props = new Properties();
            props.setProperty(KEY, Long.toString(epoch));
            try (OutputStream os = Files.newOutputStream(tmp)) {
                props.store(os, "sui-trust observer restart epoch (B6 anti-replay)");
            }
            Files.move(tmp, p, StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException e) {
            // Non-fatal: the clock-seconds floor keeps us monotonic enough that
            // gossip still flows, we just lose the tighter counter.
            LOG.warn("[trust] epoch persist failed: {}", e.getMessage());
        }
    }
}
