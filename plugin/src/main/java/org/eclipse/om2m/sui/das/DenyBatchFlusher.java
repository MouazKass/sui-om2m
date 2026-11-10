package org.eclipse.om2m.sui.das;

import java.util.ArrayDeque;
import java.util.function.LongSupplier;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

import org.eclipse.om2m.sui.sdk.NativePtbBuilder;

/**
 * v9 (F3): periodically anchors the {@link DenyLog}'s closed windows on-chain
 * via {@code evaluator::log_deny_batch}.
 *
 * <p>Each {@link #tick()} closes the open window (if it holds any DENY) and
 * submits at most ONE pending batch, oldest first, because the contract
 * accepts one batch per node per 5 minutes. Outcomes:
 * <ul>
 * <li>GRANT: anchored, dropped from the queue;</li>
 * <li>DENY_SIMULATED / DENY_EXECUTED: the contract refused it (e.g. an
 *     overlapping window after a clock step). Retried up to
 *     {@link #MAX_REFUSALS} times, then dropped with a warning. The lines
 *     stay in the local log either way;</li>
 * <li>ERROR (network, pre-check unavailable): kept for the next tick.</li>
 * </ul>
 * The queue is bounded ({@link #MAX_PENDING}); on overflow the oldest batch is
 * dropped, logged, and remains verifiable from the local file.
 *
 * <p>Off by default and on v8 ({@code sui.das.deny.audit.flush.enabled}); the
 * Move function exists only from v9.
 */
public final class DenyBatchFlusher {

    private static final Log LOG = LogFactory.getLog(DenyBatchFlusher.class);
    static final int MAX_PENDING = 16;
    static final int MAX_REFUSALS = 3;

    /** The on-chain submission, split out for tests. */
    public interface Submitter {
        NativePtbBuilder.Result submit(DenyLog.Batch b);
    }

    private final DenyLog log;
    private final Submitter submitter;
    private final LongSupplier clock;
    private final ArrayDeque<DenyLog.Batch> pending = new ArrayDeque<>();
    private int refusals;

    public DenyBatchFlusher(DenyLog log, Submitter submitter, LongSupplier clock) {
        this.log = log;
        this.submitter = submitter;
        this.clock = clock;
    }

    public synchronized void tick() {
        DenyLog.Batch closed = log.closeWindow(clock.getAsLong());
        if (closed != null) {
            if (pending.size() >= MAX_PENDING) {
                DenyLog.Batch dropped = pending.pollFirst();
                LOG.warn("DENY batch queue full; dropping un-anchored window " + dropped.windowStartMs
                         + ".." + dropped.windowEndMs + " sha256=" + dropped.sha256Hex()
                         + " (still in the local DENY log)");
                refusals = 0;
            }
            pending.addLast(closed);
        }
        DenyLog.Batch head = pending.peekFirst();
        if (head == null) return;

        NativePtbBuilder.Result r;
        try {
            r = submitter.submit(head);
        } catch (Throwable t) {
            LOG.warn("DENY batch submit error (will retry): " + t);
            return;
        }
        if (r.granted) {
            LOG.info("DENY batch anchored: window " + head.windowStartMs + ".." + head.windowEndMs
                     + " count=" + head.count + " distinct=" + head.distinct
                     + " sha256=" + head.sha256Hex() + " digest=" + r.digest);
            pending.pollFirst();
            refusals = 0;
        } else if (r.decision == NativePtbBuilder.Decision.ERROR) {
            LOG.warn("DENY batch not anchored yet (will retry): " + r.error);
        } else if (++refusals >= MAX_REFUSALS) {
            LOG.warn("DENY batch refused " + refusals + "x by the contract; dropping window "
                     + head.windowStartMs + ".." + head.windowEndMs + " sha256=" + head.sha256Hex()
                     + " (still in the local DENY log): " + r.error);
            pending.pollFirst();
            refusals = 0;
        } else {
            LOG.warn("DENY batch refused by the contract (attempt " + refusals + "): " + r.error);
        }
    }

    synchronized int pendingCount() { return pending.size(); }
}
