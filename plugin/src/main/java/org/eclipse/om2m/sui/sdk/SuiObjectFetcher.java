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
import java.util.HashMap;
import java.util.Map;

/**
 * Fetches current on-chain object state needed for TransactionData:
 *  - Shared objects: their initialSharedVersion (stable, cached)
 *  - Owned/gas objects: current version and digest (changes per tx)
 *
 * Calls sui_getObject / suix_getCoins / suix_getReferenceGasPrice on the fullnode.
 */
public final class SuiObjectFetcher {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    public static final class ObjectInfo {
        public final boolean isShared;
        public final long version;            // for shared: initialSharedVersion
        public final byte[] digestRaw32;      // null for shared (not needed)

        ObjectInfo(boolean isShared, long version, byte[] digest) {
            this.isShared = isShared;
            this.version = version;
            this.digestRaw32 = digest;
        }
    }

    private final String rpcUrl;
    private final int timeoutMs;
    private final Map<String, Long> sharedVersionCache = new HashMap<>();

    public SuiObjectFetcher(String rpcUrl) { this(rpcUrl, 15_000); }
    public SuiObjectFetcher(String rpcUrl, int timeoutMs) {
        this.rpcUrl = rpcUrl;
        this.timeoutMs = timeoutMs;
    }

    public ObjectInfo getObject(String objectId0x) throws IOException {
        Long cached = sharedVersionCache.get(objectId0x);
        if (cached != null) return new ObjectInfo(true, cached, null);

        ObjectNode req = MAPPER.createObjectNode();
        req.put("jsonrpc", "2.0");
        req.put("id", 1);
        req.put("method", "sui_getObject");
        ArrayNode params = req.putArray("params");
        params.add(objectId0x);
        ObjectNode opts = params.addObject();
        opts.put("showOwner", true);

        byte[] resp = post(MAPPER.writeValueAsString(req));
        JsonNode root = MAPPER.readTree(resp);
        if (root.has("error")) {
            throw new IOException("getObject error for " + objectId0x + ": " + root.get("error"));
        }
        JsonNode data = root.path("result").path("data");
        if (data.isMissingNode() || data.isNull()) {
            throw new IOException("getObject: no data for " + objectId0x);
        }

        JsonNode owner = data.path("owner");
        if (owner.has("Shared")) {
            long initSharedVer = owner.path("Shared").path("initial_shared_version").asLong();
            sharedVersionCache.put(objectId0x, initSharedVer);
            return new ObjectInfo(true, initSharedVer, null);
        }

        long version = data.path("version").asLong();
        String digestB58 = data.path("digest").asText();
        byte[] digestRaw = BcsEncoder.base58Decode(digestB58);
        if (digestRaw.length != 32) {
            throw new IOException("expected 32-byte digest, got " + digestRaw.length + " for " + objectId0x);
        }
        return new ObjectInfo(false, version, digestRaw);
    }

    public SuiPtbEncoder.ObjectRef pickGasCoin(String sender0x, long minBalance) throws IOException {
        ObjectNode req = MAPPER.createObjectNode();
        req.put("jsonrpc", "2.0");
        req.put("id", 1);
        req.put("method", "suix_getCoins");
        ArrayNode params = req.putArray("params");
        params.add(sender0x);
        params.add("0x2::sui::SUI");

        byte[] resp = post(MAPPER.writeValueAsString(req));
        JsonNode root = MAPPER.readTree(resp);
        if (root.has("error")) {
            throw new IOException("getCoins error: " + root.get("error"));
        }
        for (JsonNode coin : root.path("result").path("data")) {
            long balance = coin.path("balance").asLong();
            if (balance < minBalance) continue;
            String id = coin.path("coinObjectId").asText();
            long version = coin.path("version").asLong();
            String digestB58 = coin.path("digest").asText();
            return new SuiPtbEncoder.ObjectRef(
                    BcsEncoder.hexTo32(id),
                    version,
                    BcsEncoder.base58Decode(digestB58));
        }
        throw new IOException("no gas coin with balance >= " + minBalance + " for " + sender0x);
    }

    public long getReferenceGasPrice() throws IOException {
        ObjectNode req = MAPPER.createObjectNode();
        req.put("jsonrpc", "2.0");
        req.put("id", 1);
        req.put("method", "suix_getReferenceGasPrice");
        req.putArray("params");
        byte[] resp = post(MAPPER.writeValueAsString(req));
        JsonNode root = MAPPER.readTree(resp);
        if (root.has("error")) throw new IOException("getReferenceGasPrice error: " + root.get("error"));
        return root.path("result").asLong();
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
        InputStream in = (code >= 200 && code < 300) ? conn.getInputStream() : conn.getErrorStream();
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
