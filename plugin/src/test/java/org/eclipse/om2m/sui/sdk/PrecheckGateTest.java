package org.eclipse.om2m.sui.sdk;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.IOException;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.Test;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * F3: a DENY must never be submitted (and so never paid for).
 *
 * Before the fix every DENY was an executed transaction that aborted on-chain
 * and still paid ~1 mSUI, so repeating a forbidden request drained the node's
 * gas. NativePtbBuilder.precheckThenSubmit simulates the exact bytes first and
 * submits only on a successful simulation.
 */
public class PrecheckGateTest {

    private static final ObjectMapper M = new ObjectMapper();
    private static final String ABORT =
        "MoveAbort(MoveLocation { module: ModuleId { address: 0x88, name: Identifier(\"cap_token\") },"
        + " function_name: Some(\"validate_for_use\"), instruction: 31 }, 4) -- denied";
    private static final String STALE =
        "Sui GraphQL error: Transaction needs to be rebuilt because object 0x4d36 version 0x1"
        + " is unavailable for consumption, current version: 0x2 [BAD_USER_INPUT]";

    private static JsonNode status(String s, String err) {
        ObjectNode o = M.createObjectNode();
        ObjectNode st = o.putObject("effects").putObject("status");
        st.put("status", s);
        if (err != null) st.put("error", err);
        return o;
    }

    private static JsonNode executed(String s, String err) {
        ObjectNode o = (ObjectNode) status(s, err);
        o.put("digest", "DIGEST1");
        return o;
    }

    /** Scripted network: counts calls so tests can prove nothing was submitted. */
    private static final class Net implements NativePtbBuilder.TxPath {
        final AtomicInteger prechecks = new AtomicInteger();
        final AtomicInteger executes = new AtomicInteger();
        JsonNode sim;
        IOException simError;
        JsonNode exec = executed("success", null);
        String lastPrecheckedTx, lastExecutedTx;

        @Override public JsonNode precheck(String txB64) throws IOException {
            prechecks.incrementAndGet();
            lastPrecheckedTx = txB64;
            if (simError != null) throw simError;
            return sim;
        }
        @Override public JsonNode execute(String txB64) {
            executes.incrementAndGet();
            lastExecutedTx = txB64;
            return exec;
        }
    }

    @Test
    public void grantIsSimulatedThenSubmittedWithTheSameBytes() {
        Net n = new Net();
        n.sim = status("success", null);
        NativePtbBuilder.Result r = NativePtbBuilder.precheckThenSubmit(true, "TXBYTES", n, System.nanoTime());
        assertTrue(r.granted);
        assertEquals(NativePtbBuilder.Decision.GRANT, r.decision);
        assertEquals("DIGEST1", r.digest);
        assertEquals(1, n.prechecks.get());
        assertEquals(1, n.executes.get());
        assertEquals("the simulated bytes are exactly the submitted bytes", n.lastPrecheckedTx, n.lastExecutedTx);
        assertTrue(r.submitted());
    }

    @Test
    public void denyIsNeverSubmitted() {
        Net n = new Net();
        n.sim = status("failure", ABORT);
        NativePtbBuilder.Result r = NativePtbBuilder.precheckThenSubmit(true, "TX", n, System.nanoTime());
        assertFalse(r.granted);
        assertEquals(NativePtbBuilder.Decision.DENY_SIMULATED, r.decision);
        assertEquals("a DENY must not reach executeTransaction", 0, n.executes.get());
        assertFalse(r.submitted());
        assertNull(r.digest);
        assertTrue("abort kept for AbortDecoder", r.error.contains("Identifier(\"cap_token\")"));
        assertTrue(r.error.contains("}, 4)"));
    }

    @Test
    public void precheckUnavailableFailsClosedWithoutPaying() {
        Net n = new Net();
        n.simError = new IOException("connect timed out");
        NativePtbBuilder.Result r = NativePtbBuilder.precheckThenSubmit(true, "TX", n, System.nanoTime());
        assertFalse(r.granted);
        assertEquals(NativePtbBuilder.Decision.ERROR, r.decision);
        assertEquals(0, n.executes.get());
        assertTrue(r.error.contains("fail closed"));
    }

    @Test
    public void unrecognisedSimulationStatusFailsClosed() {
        Net n = new Net();
        n.sim = status("unknown", "effects status missing");
        NativePtbBuilder.Result r = NativePtbBuilder.precheckThenSubmit(true, "TX", n, System.nanoTime());
        assertFalse(r.granted);
        assertEquals(NativePtbBuilder.Decision.ERROR, r.decision);
        assertEquals(0, n.executes.get());
    }

    @Test
    public void staleVersionAtPrecheckIsRebuiltNotDenied() {
        // A refused input (indexer lag) is not a verdict: withStaleRetry must
        // still recognise it and rebuild, exactly as for a submitted tx.
        Net n = new Net();
        n.simError = new IOException(STALE);
        NativePtbBuilder.Result first = NativePtbBuilder.precheckThenSubmit(true, "TX", n, System.nanoTime());
        assertTrue(NativePtbBuilder.isStaleObjectVersion(first.error));

        AtomicInteger builds = new AtomicInteger();
        Net ok = new Net();
        ok.sim = status("success", null);
        NativePtbBuilder.Result r = NativePtbBuilder.withStaleRetry(() ->
            builds.incrementAndGet() == 1
                ? NativePtbBuilder.precheckThenSubmit(true, "TX", n, System.nanoTime())
                : NativePtbBuilder.precheckThenSubmit(true, "TX", ok, System.nanoTime()));
        assertTrue(r.granted);
        assertEquals(2, builds.get());
        assertEquals(0, n.executes.get());
    }

    @Test
    public void executedFailureAfterASuccessfulPrecheckIsReportedAsPaid() {
        // State can change between simulation and execution (e.g. a policy
        // write lands in between). That rare DENY is paid and labelled so.
        Net n = new Net();
        n.sim = status("success", null);
        n.exec = executed("failure", ABORT);
        NativePtbBuilder.Result r = NativePtbBuilder.precheckThenSubmit(true, "TX", n, System.nanoTime());
        assertFalse(r.granted);
        assertEquals(NativePtbBuilder.Decision.DENY_EXECUTED, r.decision);
        assertTrue(r.submitted());
    }

    @Test
    public void disablingThePrecheckSubmitsDirectly() {
        Net n = new Net();
        NativePtbBuilder.Result r = NativePtbBuilder.precheckThenSubmit(false, "TX", n, System.nanoTime());
        assertTrue(r.granted);
        assertEquals(0, n.prechecks.get());
        assertEquals(1, n.executes.get());
    }

    @Test
    public void precheckQueryEnablesEveryInputCheck() {
        // checksEnabled:false would skip ownership/version/gas checks and could
        // predict a GRANT the real submission then aborts (and pays for).
        assertTrue(SuiRpcClient.Q_PRECHECK.contains("checksEnabled:true"));
        assertFalse(SuiRpcClient.Q_PRECHECK.contains("checksEnabled:false"));
    }

    @Test
    public void precheckReshapesGraphQlFailureIntoAbortForm() throws Exception {
        JsonNode data = M.readTree("{\"simulateTransaction\":{\"effects\":{\"status\":\"FAILURE\","
            + "\"executionError\":{\"message\":\"denied\",\"abortCode\":\"4\",\"instructionOffset\":31,"
            + "\"module\":{\"name\":\"cap_token\",\"package\":{\"address\":\"0x88\"}},"
            + "\"function\":{\"name\":\"validate_for_use\"}}}}}");
        JsonNode st = SuiRpcClient.reshapePrecheck(data).path("effects").path("status");
        assertEquals("failure", st.path("status").asText());
        assertTrue(st.path("error").asText().startsWith("MoveAbort(MoveLocation { module: ModuleId { address: 0x88"));
        JsonNode ok = SuiRpcClient.reshapePrecheck(M.readTree(
            "{\"simulateTransaction\":{\"effects\":{\"status\":\"SUCCESS\"}}}"));
        assertEquals("success", ok.path("effects").path("status").path("status").asText());
    }

    @Test(expected = IOException.class)
    public void precheckWithoutEffectsIsAnError() throws Exception {
        SuiRpcClient.reshapePrecheck(M.readTree("{\"simulateTransaction\":{}}"));
    }
}
