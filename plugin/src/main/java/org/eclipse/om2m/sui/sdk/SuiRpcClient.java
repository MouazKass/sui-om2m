package org.eclipse.om2m.sui.sdk;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.List;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

/**
 * Native JSON-RPC client for sui_executeTransactionBlock. Avoids the
 * shell-out overhead of the CLI by submitting a pre-built BCS-encoded
 * transaction directly to the fullnode with WaitForEffectsCert finality.
 *
 * Tested round-trip on testnet: ~1.1s vs ~5.7s for `sui client ptb`.
 */
public final class SuiRpcClient {

    private static final Log LOG = LogFactory.getLog(SuiRpcClient.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final int DEFAULT_TIMEOUT_MS = 30_000;

    private final String rpcUrl;
    private final int timeoutMs;

    public SuiRpcClient(String rpcUrl) {
        this(rpcUrl, DEFAULT_TIMEOUT_MS);
    }

    public SuiRpcClient(String rpcUrl, int timeoutMs) {
        this.rpcUrl = rpcUrl;
        this.timeoutMs = timeoutMs;
    }

    /**
     * Submit a signed transaction. tx_bytes and signature are base64.
     * Returns the parsed result (digest, effects, etc).
     *
     * @param txBytesB64 base64-encoded BCS TransactionData
     * @param signaturesB64 base64-encoded signatures (with scheme byte prefix)
     * @return parsed JsonNode of result
     */
    public JsonNode executeTransactionBlock(String txBytesB64,
                                            List<String> signaturesB64)
            throws IOException {
        ObjectNode root = MAPPER.createObjectNode();
        root.put("jsonrpc", "2.0");
        root.put("id", 1);
        root.put("method", "sui_executeTransactionBlock");

        ArrayNode params = root.putArray("params");
        params.add(txBytesB64);
        ArrayNode sigs = params.addArray();
        for (String s : signaturesB64) sigs.add(s);
        ObjectNode opts = params.addObject();
        opts.put("showEffects", true);
        opts.put("showEvents", true);
        params.add("WaitForEffectsCert");

        String body = MAPPER.writeValueAsString(root);
        byte[] respBytes = post(body);
        JsonNode resp = MAPPER.readTree(respBytes);

        if (resp.has("error")) {
            throw new IOException("Sui RPC error: " + resp.get("error").toString());
        }
        return resp.get("result");
    }

    private byte[] post(String body) throws IOException {
        HttpURLConnection conn = (HttpURLConnection) new URL(rpcUrl).openConnection();
        conn.setRequestMethod("POST");
        conn.setConnectTimeout(timeoutMs);
        conn.setReadTimeout(timeoutMs);
        conn.setRequestProperty("Content-Type", "application/json");
        conn.setDoOutput(true);
        try (OutputStream os = conn.getOutputStream()) {
            os.write(body.getBytes(StandardCharsets.UTF_8));
        }
        int code = conn.getResponseCode();
        InputStream in = (code >= 200 && code < 300)
                ? conn.getInputStream() : conn.getErrorStream();
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        if (in != null) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) baos.write(buf, 0, n);
        }
        byte[] out = baos.toByteArray();
        if (code < 200 || code >= 300) {
            throw new IOException("HTTP " + code + ": " + new String(out, StandardCharsets.UTF_8));
        }
        return out;
    }
}
