package org.eclipse.om2m.sui.sdk;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

/**
 * Minimal Sui GraphQL transport (POST {@code {"query","variables"}}).
 *
 * <p>Replaces the fullnode JSON-RPC transport, which Sui has deprecated on
 * public fullnodes (every method now answers {@code -32601 Method not found}).
 * {@link SuiObjectFetcher} and {@link SuiRpcClient} keep their public API and
 * use this class underneath, reshaping GraphQL answers into what their callers
 * already read.
 *
 * <p><b>Failure contract.</b> {@link #execute} never returns a partial or empty
 * answer as success. It throws {@link IOException} when:
 * <ul>
 *   <li>the HTTP status is not 2xx,</li>
 *   <li>the body is not a JSON object,</li>
 *   <li>the response carries a non-empty {@code errors} array (even if
 *       {@code data} is partially populated), or</li>
 *   <li>{@code data} is missing or null.</li>
 * </ul>
 * A {@code null} <i>field</i> inside {@code data} (e.g. {@code object: null}) is
 * a legitimate "not found" answer and is left to the caller to interpret.
 *
 * <p><b>Endpoint resolution.</b> Callers across the plugin still hand the SDK
 * the legacy {@code sui.rpc.url} value. {@link #resolveEndpoint} maps it:
 * an explicit GraphQL URL (path ending in {@code /graphql}) is used as-is;
 * otherwise the process-wide endpoint registered by {@code SuiConfig.load()}
 * from {@code sui.graphql.url} wins; otherwise the public Sui fullnode host is
 * mapped to its GraphQL twin; otherwise the testnet default is used (warned).
 *
 * <p>Java 8 compatible: HttpURLConnection + Jackson only.
 */
public final class SuiGraphQlClient {

    private static final Log LOG = LogFactory.getLog(SuiGraphQlClient.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();

    /** Default endpoint, matching {@code SuiConfig}'s {@code sui.graphql.url} default. */
    public static final String DEFAULT_TESTNET_URL = "https://graphql.testnet.sui.io/graphql";

    /** Process-wide endpoint from {@code sui.graphql.url}; null until SuiConfig loads. */
    private static volatile String configuredEndpoint;

    private final String endpoint;
    private final int timeoutMs;

    public SuiGraphQlClient(String urlOrLegacyRpcUrl, int timeoutMs) {
        this.endpoint = resolveEndpoint(urlOrLegacyRpcUrl);
        this.timeoutMs = timeoutMs;
    }

    public String endpoint() { return endpoint; }

    // ------------------------------------------------------------------
    //  Endpoint resolution
    // ------------------------------------------------------------------

    /** Register the endpoint configured via {@code sui.graphql.url}. Null/blank clears it. */
    public static void setConfiguredEndpoint(String url) {
        configuredEndpoint = (url == null || url.trim().isEmpty()) ? null : url.trim();
    }

    /** @return the endpoint registered by {@link #setConfiguredEndpoint}, or null. */
    public static String configuredEndpoint() { return configuredEndpoint; }

    public static boolean isGraphQlUrl(String url) {
        if (url == null) return false;
        String u = url.trim();
        while (u.endsWith("/")) u = u.substring(0, u.length() - 1);
        return u.endsWith("/graphql");
    }

    /**
     * Map a legacy fullnode JSON-RPC URL onto the matching public GraphQL
     * endpoint. Unknown hosts fall back to {@link #DEFAULT_TESTNET_URL} with a
     * warning (set {@code sui.graphql.url} explicitly for private nodes).
     */
    public static String deriveFromRpcUrl(String rpcUrl) {
        if (rpcUrl == null || rpcUrl.trim().isEmpty()) return DEFAULT_TESTNET_URL;
        if (isGraphQlUrl(rpcUrl)) return rpcUrl.trim();
        String host = null;
        try {
            host = new URI(rpcUrl.trim()).getHost();
        } catch (Exception ignored) {
            // fall through
        }
        if (host != null) {
            host = host.toLowerCase();
            if (host.equals("fullnode.testnet.sui.io")) return "https://graphql.testnet.sui.io/graphql";
            if (host.equals("fullnode.mainnet.sui.io")) return "https://graphql.mainnet.sui.io/graphql";
            if (host.equals("fullnode.devnet.sui.io"))  return "https://graphql.devnet.sui.io/graphql";
        }
        LOG.warn("No GraphQL endpoint known for RPC URL '" + rpcUrl + "'; using "
                 + DEFAULT_TESTNET_URL + ". Set sui.graphql.url explicitly.");
        return DEFAULT_TESTNET_URL;
    }

    /** See class javadoc for the precedence order. */
    public static String resolveEndpoint(String urlOrLegacyRpcUrl) {
        if (isGraphQlUrl(urlOrLegacyRpcUrl)) return urlOrLegacyRpcUrl.trim();
        String c = configuredEndpoint;
        if (c != null) return c;
        return deriveFromRpcUrl(urlOrLegacyRpcUrl);
    }

    // ------------------------------------------------------------------
    //  Request / response
    // ------------------------------------------------------------------

    public static ObjectNode vars() { return MAPPER.createObjectNode(); }

    /**
     * Run a query/mutation and return its {@code data} object.
     * @throws IOException on HTTP failure, GraphQL errors, or null data.
     */
    public JsonNode execute(String query, JsonNode variables) throws IOException {
        ObjectNode body = MAPPER.createObjectNode();
        body.put("query", query);
        body.set("variables", variables == null ? MAPPER.createObjectNode() : variables);
        byte[] req = MAPPER.writeValueAsBytes(body);

        HttpURLConnection conn = (HttpURLConnection) new URL(endpoint).openConnection();
        conn.setRequestMethod("POST");
        conn.setConnectTimeout(timeoutMs);
        conn.setReadTimeout(timeoutMs);
        conn.setRequestProperty("Content-Type", "application/json");
        conn.setRequestProperty("Accept", "application/json");
        conn.setDoOutput(true);
        try (OutputStream os = conn.getOutputStream()) {
            os.write(req);
        }
        int code = conn.getResponseCode();
        InputStream in = (code >= 200 && code < 300) ? conn.getInputStream() : conn.getErrorStream();
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        if (in != null) {
            try {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) baos.write(buf, 0, n);
            } finally {
                in.close();
            }
        }
        return parseResponse(code, baos.toByteArray());
    }

    /**
     * Validate a raw GraphQL HTTP response and return {@code data}. Pure
     * function, exposed for hermetic tests.
     */
    public static JsonNode parseResponse(int httpCode, byte[] body) throws IOException {
        String text = body == null ? "" : new String(body, StandardCharsets.UTF_8);
        if (httpCode < 200 || httpCode >= 300) {
            throw new IOException("Sui GraphQL HTTP " + httpCode + ": " + abbreviate(text));
        }
        JsonNode root;
        try {
            root = MAPPER.readTree(text);
        } catch (IOException e) {
            throw new IOException("Sui GraphQL: response is not JSON: " + abbreviate(text), e);
        }
        if (root == null || !root.isObject()) {
            throw new IOException("Sui GraphQL: response is not a JSON object: " + abbreviate(text));
        }
        JsonNode errors = root.path("errors");
        if (errors.isArray() && errors.size() > 0) {
            StringBuilder sb = new StringBuilder("Sui GraphQL error: ");
            for (int i = 0; i < errors.size(); i++) {
                if (i > 0) sb.append(" | ");
                JsonNode e = errors.get(i);
                sb.append(e.path("message").asText(e.toString()));
                JsonNode c = e.path("extensions").path("code");
                if (c.isTextual()) sb.append(" [").append(c.asText()).append(']');
            }
            throw new IOException(sb.toString());
        }
        JsonNode data = root.path("data");
        if (data.isMissingNode() || data.isNull() || !data.isObject()) {
            throw new IOException("Sui GraphQL: response has no data: " + abbreviate(text));
        }
        return data;
    }

    /**
     * Read an integer that GraphQL may encode as a JSON number (UInt53/Int)
     * or as a decimal string (BigInt, Move u64). Missing/null/non-numeric
     * values throw instead of silently becoming 0.
     */
    public static long requireLong(JsonNode n, String what) throws IOException {
        if (n == null || n.isMissingNode() || n.isNull()) {
            throw new IOException("Sui GraphQL: missing numeric field " + what);
        }
        if (n.isIntegralNumber() && n.canConvertToLong()) return n.longValue();
        if (n.isTextual()) {
            try {
                return Long.parseLong(n.asText().trim());
            } catch (NumberFormatException e) {
                throw new IOException("Sui GraphQL: non-numeric " + what + ": " + n.asText());
            }
        }
        throw new IOException("Sui GraphQL: unexpected type for " + what + ": " + n);
    }

    static String abbreviate(String s) {
        if (s == null) return "";
        return s.length() <= 500 ? s : s.substring(0, 500) + "...";
    }
}
