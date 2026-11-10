package org.eclipse.om2m.sui.das;

import static org.junit.Assert.assertEquals;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

import org.junit.Test;

import org.eclipse.om2m.sui.sdk.NativePtbBuilder;
import org.eclipse.om2m.sui.sdk.NativePtbBuilder.Decision;

/** v9 (F3): DENY windows are anchored one per tick, oldest first, with bounded retries. */
public class DenyBatchFlusherTest {

    private final AtomicLong now = new AtomicLong(1_000L);
    private final DenyLog log = new DenyLog(null, 1 << 20, 0);
    private final List<DenyLog.Batch> sent = new ArrayList<>();
    private Decision next = Decision.GRANT;

    private DenyBatchFlusher flusher() {
        return new DenyBatchFlusher(log, b -> {
            sent.add(b);
            return new NativePtbBuilder.Result(next == Decision.GRANT, next == Decision.GRANT ? "D" : null,
                                               1L, next == Decision.GRANT ? null : "refused", next);
        }, now::get);
    }

    private void deny() {
        log.append(now.getAndIncrement(), "Cs", "0xa", "/r", (byte) 4, "SIMULATED", "abort");
    }

    @Test
    public void nothingToSendSendsNothing() {
        DenyBatchFlusher f = flusher();
        f.tick();
        assertEquals(0, sent.size());
    }

    @Test
    public void aClosedWindowIsAnchoredAndDropped() {
        DenyBatchFlusher f = flusher();
        deny(); deny();
        f.tick();
        assertEquals(1, sent.size());
        assertEquals(2, sent.get(0).count);
        assertEquals(0, f.pendingCount());
    }

    @Test
    public void transportErrorsKeepTheBatchForTheNextTick() {
        DenyBatchFlusher f = flusher();
        next = Decision.ERROR;
        deny();
        f.tick(); f.tick(); f.tick(); f.tick();
        assertEquals(1, f.pendingCount());
        next = Decision.GRANT;
        f.tick();
        assertEquals(0, f.pendingCount());
        assertEquals(sent.get(0).windowStartMs, sent.get(sent.size() - 1).windowStartMs);
    }

    @Test
    public void aContractRefusalIsRetriedABoundedNumberOfTimesThenDropped() {
        DenyBatchFlusher f = flusher();
        next = Decision.DENY_SIMULATED;
        deny();
        for (int i = 0; i < DenyBatchFlusher.MAX_REFUSALS; i++) f.tick();
        assertEquals(0, f.pendingCount());
        assertEquals(DenyBatchFlusher.MAX_REFUSALS, sent.size());
    }

    @Test
    public void atMostOneSubmissionPerTickOldestFirst() {
        // The contract accepts one batch per node per 5 min, so a backlog drains one per tick.
        DenyBatchFlusher f = flusher();
        next = Decision.ERROR;
        deny(); f.tick();             // window 1 pending
        deny(); f.tick();             // window 2 pending
        assertEquals(2, f.pendingCount());
        int before = sent.size();
        next = Decision.GRANT;
        f.tick();
        assertEquals(before + 1, sent.size());
        assertEquals(1, f.pendingCount());
        long firstStart = sent.get(sent.size() - 1).windowStartMs;
        f.tick();
        assertEquals(0, f.pendingCount());
        assertEquals(true, sent.get(sent.size() - 1).windowStartMs > firstStart);
    }

    @Test
    public void theQueueIsBounded() {
        DenyBatchFlusher f = flusher();
        next = Decision.ERROR;
        for (int i = 0; i < DenyBatchFlusher.MAX_PENDING + 5; i++) { deny(); f.tick(); }
        assertEquals(DenyBatchFlusher.MAX_PENDING, f.pendingCount());
    }
}
