package org.eclipse.om2m.sui.sdk;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.IOException;
import java.util.Base64;
import java.util.List;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

/**
 * Transaction submission / dev-inspect client.
 *
 * <p>Historically this spoke fullnode JSON-RPC ({@code sui_executeTransactionBlock},
 * {@code sui_devInspectTransactionBlock}). Public fullnodes have deprecated
 * JSON-RPC, so both methods now go over Sui GraphQL
 * ({@code executeTransaction} / {@code simulateTransaction}) and the GraphQL
 * answer is reshaped into the subset of the JSON-RPC result shape that callers
 * read, so callers are unchanged:
 *
 * <pre>
 * executeTransactionBlock -&gt; { "digest": D,
 *                               "effects": { "transactionDigest": D,
 *                                            "status": { "status": "success"|"failure", "error": E } } }
 * devInspectTransactionBlock -&gt; { "effects": { "status": {...} },
 *                                  "results": [ { "returnValues": [ [ [u8,...], "type" ], ... ] }, ... ],
 *                                  "error": E   (only on failure; "results" is then omitted) }
 * </pre>
 *
 * <p>On a Move abort the {@code error} string is rendered in the JSON-RPC
 * {@code MoveAbort(MoveLocation { ... name: Identifier("m") ... }, code)} form
 * (followed by the GraphQL message) so {@code das.AbortDecoder} keeps decoding it.
 */
public final class SuiRpcClient {

    private static final Log LOG = LogFactory.getLog(SuiRpcClient.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final int DEFAULT_TIMEOUT_MS = 30_000;

    /** Gas budget encoded into the synthetic TransactionData used for dev-inspect. */
    static final long DEV_INSPECT_GAS_BUDGET = 50_000_000L;
    /** How long the reference gas price used for dev-inspect is reused. */
    static final long RGP_CACHE_MS = 60_000L;

    private static final String EXEC_ERROR_FIELDS =
        "executionError { message abortCode instructionOffset"
        + " module { name package { address } } function { name } }";

    static final String M_EXECUTE =
        "mutation($tx:Base64!,$sigs:[Base64!]!){"
        + " executeTransaction(transactionDataBcs:$tx, signatures:$sigs){"
        + " effects { digest status " + EXEC_ERROR_FIELDS + " } } }";

    static final String Q_SIMULATE =
        "query($tx:JSON!){ simulateTransaction(transaction:$tx, checksEnabled:false){"
        + " effects { digest status " + EXEC_ERROR_FIELDS + " }"
        + " outputs { returnValues { value { type { repr } bcs } } } } }";

    /**
     * F3 pre-check: simulate the EXACT TransactionData that will be signed and
     * submitted (same sender, gas coin, gas price/budget, object versions and
     * commands), with every input/gas check enabled. Free: no signature, no gas,
     * nothing is committed.
     */
    static final String Q_PRECHECK =
        "query($tx:JSON!){ simulateTransaction(transaction:$tx, checksEnabled:true){"
        + " effects { status " + EXEC_ERROR_FIELDS + " } } }";

    private final SuiGraphQlClient gql;
    private final SuiObjectFetcher fetcher;   // for the reference gas price only
    private volatile long cachedRgp = -1L;
    private volatile long cachedRgpAtMs = 0L;

    public SuiRpcClient(String rpcUrl) {
        this(rpcUrl, DEFAULT_TIMEOUT_MS);
    }

    public SuiRpcClient(String rpcUrl, int timeoutMs) {
        this.gql = new SuiGraphQlClient(rpcUrl, timeoutMs);
        this.fetcher = new SuiObjectFetcher(rpcUrl, timeoutMs);
    }

    public String endpoint() { return gql.endpoint(); }

    /**
     * Submit a signed transaction. tx_bytes and signature are base64.
     * Waits for finality (GraphQL {@code executeTransaction} semantics).
     *
     * @param txBytesB64 base64-encoded BCS TransactionData
     * @param signaturesB64 base64-encoded signatures (flag || sig || pubkey)
     * @return JSON-RPC-shaped result (digest, effects.status)
     */
    public JsonNode executeTransactionBlock(String txBytesB64,
                                            List<String> signaturesB64)
            throws IOException {
        ObjectNode v = SuiGraphQlClient.vars();
        v.put("tx", txBytesB64);
        ArrayNode sigs = v.putArray("sigs");
        for (String s : signaturesB64) sigs.add(s);
        return reshapeExecution(gql.execute(M_EXECUTE, v));
    }

    /** Pure reshaper for {@link #M_EXECUTE}'s data. */
    static JsonNode reshapeExecution(JsonNode data) throws IOException {
        JsonNode res = data.path("executeTransaction");
        if (res.isMissingNode() || res.isNull()) {
            throw new IOException("Sui GraphQL: executeTransaction returned no result");
        }
        JsonNode effects = res.path("effects");
        if (effects.isMissingNode() || effects.isNull()) {
            throw new IOException("Sui GraphQL: executeTransaction returned no effects");
        }
        String digest = effects.path("digest").asText("");
        ObjectNode out = MAPPER.createObjectNode();
        if (!digest.isEmpty()) out.put("digest", digest);
        ObjectNode eff = out.putObject("effects");
        if (!digest.isEmpty()) eff.put("transactionDigest", digest);
        eff.set("status", statusNode(effects));
        return out;
    }

    /**
     * Free pre-check of a full, unsigned TransactionData (see {@link #Q_PRECHECK}).
     *
     * @return {@code {"effects":{"status":{"status":"success"|"failure"|"unknown","error":E}}}}
     * @throws IOException transport/GraphQL errors (including a refused input
     *         such as a stale object version); callers fail closed on these
     */
    public JsonNode precheckTransaction(String txBytesB64) throws IOException {
        ObjectNode v = SuiGraphQlClient.vars();
        v.putObject("tx").putObject("bcs").put("value", txBytesB64);
        return reshapePrecheck(gql.execute(Q_PRECHECK, v));
    }

    /** Pure reshaper for {@link #Q_PRECHECK}'s data. */
    static JsonNode reshapePrecheck(JsonNode data) throws IOException {
        JsonNode sim = data.path("simulateTransaction");
        if (sim.isMissingNode() || sim.isNull()) {
            throw new IOException("Sui GraphQL: simulateTransaction returned no result");
        }
        JsonNode effects = sim.path("effects");
        if (effects.isMissingNode() || effects.isNull()) {
            throw new IOException("Sui GraphQL: simulateTransaction returned no effects");
        }
        ObjectNode out = MAPPER.createObjectNode();
        out.putObject("effects").set("status", statusNode(effects));
        return out;
    }

    /** Dev-inspect a transaction kind (read-only, no gas, no signature). */
    public JsonNode devInspectTransactionBlock(String senderHex,
                                               String kindBytesB64)
            throws IOException {
        byte[] kind = Base64.getDecoder().decode(kindBytesB64);
        byte[] txData = wrapKindForSimulation(kind, BcsEncoder.hexTo32(senderHex),
                                              referenceGasPrice(), DEV_INSPECT_GAS_BUDGET);
        ObjectNode v = SuiGraphQlClient.vars();
        v.putObject("tx").putObject("bcs").put("value", Base64.getEncoder().encodeToString(txData));
        return reshapeSimulation(gql.execute(Q_SIMULATE, v));
    }

    /**
     * {@code simulateTransaction} needs a full TransactionData, whereas
     * devInspect took a bare TransactionKind. Wrap the kind as
     * {@code TransactionData::V1 { kind, sender, gas_data { payment: [],
     * owner: sender, price, budget }, expiration: None }}. An empty gas payment
     * is accepted by simulation (verified on testnet); the price must be at
     * least the reference gas price.
     */
    static byte[] wrapKindForSimulation(byte[] kind, byte[] sender32, long gasPrice, long gasBudget) {
        BcsEncoder e = new BcsEncoder();
        e.writeUleb128(0);            // TransactionData::V1
        e.writeRawBytes(kind);        // TransactionKind
        e.writeAddress(sender32);     // sender
        e.writeUleb128(0);            // gas_data.payment: empty
        e.writeAddress(sender32);     // gas_data.owner
        e.writeU64(gasPrice);         // gas_data.price
        e.writeU64(gasBudget);        // gas_data.budget
        e.writeUleb128(0);            // expiration: None
        return e.toBytes();
    }

    private long referenceGasPrice() throws IOException {
        long now = System.currentTimeMillis();
        long rgp = cachedRgp;
        if (rgp > 0 && now - cachedRgpAtMs < RGP_CACHE_MS) return rgp;
        rgp = fetcher.getReferenceGasPrice();
        cachedRgp = rgp;
        cachedRgpAtMs = now;
        return rgp;
    }

    /** Pure reshaper for {@link #Q_SIMULATE}'s data into the devInspect result shape. */
    static JsonNode reshapeSimulation(JsonNode data) throws IOException {
        JsonNode sim = data.path("simulateTransaction");
        if (sim.isMissingNode() || sim.isNull()) {
            throw new IOException("Sui GraphQL: simulateTransaction returned no result");
        }
        JsonNode effects = sim.path("effects");
        if (effects.isMissingNode() || effects.isNull()) {
            throw new IOException("Sui GraphQL: simulateTransaction returned no effects");
        }
        ObjectNode out = MAPPER.createObjectNode();
        ObjectNode status = statusNode(effects);
        out.putObject("effects").set("status", status);
        if (!"success".equals(status.path("status").asText())) {
            // Like devInspect: an aborted execution carries an error and no
            // results, so callers can never read a partial return value.
            out.put("error", status.path("error").asText("simulation did not succeed"));
            return out;
        }
        ArrayNode results = out.putArray("results");
        JsonNode outputs = sim.path("outputs");
        if (!outputs.isArray()) {
            throw new IOException("Sui GraphQL: simulateTransaction returned no outputs");
        }
        for (JsonNode cmd : outputs) {
            ObjectNode r = results.addObject();
            ArrayNode rvs = r.putArray("returnValues");
            JsonNode rv = cmd.path("returnValues");
            if (!rv.isArray()) continue;
            for (JsonNode o : rv) {
                JsonNode bcs = o.path("value").path("bcs");
                if (!bcs.isTextual()) {
                    throw new IOException("Sui GraphQL: return value without BCS: " + o);
                }
                byte[] raw = Base64.getDecoder().decode(bcs.asText());
                ArrayNode pair = rvs.addArray();
                ArrayNode bytes = pair.addArray();
                for (byte b : raw) bytes.add(b & 0xFF);
                pair.add(o.path("value").path("type").path("repr").asText(""));
            }
        }
        return out;
    }

    /** effects -&gt; JSON-RPC {@code {"status": "success"|"failure"|"unknown", "error": ...}}. */
    static ObjectNode statusNode(JsonNode effects) {
        ObjectNode st = MAPPER.createObjectNode();
        String s = effects.path("status").asText("");
        if ("SUCCESS".equals(s)) {
            st.put("status", "success");
        } else if ("FAILURE".equals(s)) {
            st.put("status", "failure");
            st.put("error", formatExecutionError(effects.path("executionError")));
        } else {
            st.put("status", "unknown");
            st.put("error", "Sui GraphQL: effects status missing or unrecognised: '" + s + "'");
        }
        return st;
    }

    /**
     * Render a GraphQL ExecutionError. Move aborts get a JSON-RPC-compatible
     * prefix so {@code AbortDecoder}'s regexes keep matching; everything else
     * is the GraphQL message verbatim.
     */
    static String formatExecutionError(JsonNode err) {
        if (err == null || err.isMissingNode() || err.isNull()) {
            return "transaction failed (no executionError reported)";
        }
        String msg = err.path("message").asText("transaction failed");
        JsonNode code = err.path("abortCode");
        String module = err.path("module").path("name").asText("");
        if (code.isMissingNode() || code.isNull() || module.isEmpty()) return msg;
        String pkg = err.path("module").path("package").path("address").asText("?");
        String fn = err.path("function").path("name").asText("");
        StringBuilder sb = new StringBuilder("MoveAbort(MoveLocation { module: ModuleId { address: ")
            .append(pkg).append(", name: Identifier(\"").append(module).append("\") }");
        if (!fn.isEmpty()) sb.append(", function_name: Some(\"").append(fn).append("\")");
        JsonNode off = err.path("instructionOffset");
        if (off.isNumber()) sb.append(", instruction: ").append(off.asInt());
        sb.append(" }, ").append(code.asText()).append(") -- ").append(msg);
        return sb.toString();
    }
}
