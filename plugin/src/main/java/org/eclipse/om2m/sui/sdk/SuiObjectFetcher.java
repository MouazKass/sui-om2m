package org.eclipse.om2m.sui.sdk;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.IOException;
import java.math.BigInteger;
import java.util.HashMap;
import java.util.Map;

/**
 * Fetches current on-chain object state needed for TransactionData:
 *  - Shared objects: their initialSharedVersion (stable, cached)
 *  - Owned/gas objects: current version and digest (changes per tx)
 *
 * <p>Transport: Sui GraphQL (see {@link SuiGraphQlClient}). This replaces the
 * former sui_getObject / suix_getCoins / suix_getReferenceGasPrice JSON-RPC
 * calls, which public fullnodes no longer serve. The constructor still accepts
 * the legacy {@code sui.rpc.url} value and resolves it to a GraphQL endpoint.
 */
public final class SuiObjectFetcher {

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

    static final String Q_OBJECT =
        "query($id:SuiAddress!){ object(address:$id){ address version digest"
        + " owner { __typename ... on Shared { initialSharedVersion } } } }";

    static final String Q_OBJECT_JSON =
        "query($id:SuiAddress!){ object(address:$id){ address version"
        + " asMoveObject { contents { type { repr } json } } } }";

    static final String SUI_COIN_TYPE = "0x2::coin::Coin<0x2::sui::SUI>";

    static final String Q_COINS =
        "query($owner:SuiAddress!,$type:String!,$after:String){ address(address:$owner){"
        + " objects(first:50, after:$after, filter:{type:$type}){"
        + " pageInfo { hasNextPage endCursor }"
        + " nodes { address version digest contents { json } } } } }";

    static final String Q_RGP = "{ epoch { epochId referenceGasPrice } }";

    static final String Q_DYNAMIC_FIELD =
        "query($id:SuiAddress!,$type:String!,$bcs:Base64!){ object(address:$id){ address"
        + " dynamicField(name:{type:$type, bcs:$bcs}){"
        + " value { __typename ... on MoveValue { json } ... on MoveObject { contents { json } } } } } }";

    /** Upper bound on coin pages scanned by {@link #pickGasCoin} (50 coins/page). */
    static final int MAX_COIN_PAGES = 4;

    private final SuiGraphQlClient gql;
    private final Map<String, Long> sharedVersionCache = new HashMap<>();

    public SuiObjectFetcher(String rpcUrl) { this(rpcUrl, 15_000); }
    public SuiObjectFetcher(String rpcUrl, int timeoutMs) {
        this.gql = new SuiGraphQlClient(rpcUrl, timeoutMs);
    }

    public String endpoint() { return gql.endpoint(); }

    public ObjectInfo getObject(String objectId0x) throws IOException {
        Long cached = sharedVersionCache.get(objectId0x);
        if (cached != null) return new ObjectInfo(true, cached, null);

        ObjectNode v = SuiGraphQlClient.vars();
        v.put("id", objectId0x);
        ObjectInfo info = parseObjectInfo(gql.execute(Q_OBJECT, v), objectId0x);
        if (info.isShared) sharedVersionCache.put(objectId0x, info.version);
        return info;
    }

    /** Pure parser for {@link #Q_OBJECT}'s data. */
    static ObjectInfo parseObjectInfo(JsonNode data, String objectId0x) throws IOException {
        JsonNode obj = data.path("object");
        if (obj.isMissingNode() || obj.isNull()) {
            throw new IOException("getObject: no data for " + objectId0x + " (object not found)");
        }
        JsonNode owner = obj.path("owner");
        String kind = owner.path("__typename").asText("");
        if (kind.isEmpty()) {
            throw new IOException("getObject: no owner information for " + objectId0x);
        }
        if ("Shared".equals(kind)) {
            long initSharedVer = SuiGraphQlClient.requireLong(
                    owner.path("initialSharedVersion"), "initialSharedVersion of " + objectId0x);
            return new ObjectInfo(true, initSharedVer, null);
        }

        long version = SuiGraphQlClient.requireLong(obj.path("version"), "version of " + objectId0x);
        String digestB58 = obj.path("digest").asText("");
        if (digestB58.isEmpty()) {
            throw new IOException("getObject: no digest for " + objectId0x);
        }
        byte[] digestRaw = BcsEncoder.base58Decode(digestB58);
        if (digestRaw.length != 32) {
            throw new IOException("expected 32-byte digest, got " + digestRaw.length + " for " + objectId0x);
        }
        return new ObjectInfo(false, version, digestRaw);
    }

    /**
     * Current contents of a Move object as GraphQL JSON (u64 as decimal
     * strings, addresses canonical 0x-hex, vector&lt;u8&gt; as base64).
     * Throws if the object does not exist or is not a Move object.
     */
    public JsonNode getMoveObjectJson(String objectId0x) throws IOException {
        ObjectNode v = SuiGraphQlClient.vars();
        v.put("id", objectId0x);
        return parseMoveObjectJson(gql.execute(Q_OBJECT_JSON, v), objectId0x);
    }

    static JsonNode parseMoveObjectJson(JsonNode data, String objectId0x) throws IOException {
        JsonNode obj = data.path("object");
        if (obj.isMissingNode() || obj.isNull()) {
            throw new IOException("getObject: no data for " + objectId0x + " (object not found)");
        }
        JsonNode json = obj.path("asMoveObject").path("contents").path("json");
        if (json.isMissingNode() || json.isNull()) {
            throw new IOException("getObject: " + objectId0x + " has no Move contents");
        }
        return json;
    }

    /**
     * Value of the dynamic field named ({@code nameType}, BCS {@code nameBcsB64})
     * on {@code parentId0x}. MoveValue and MoveObject values are both handled.
     *
     * @return the value's GraphQL JSON, or {@code null} if the parent exists
     *         but has no field with that name.
     * @throws IOException if the parent object does not exist or the query fails.
     */
    public JsonNode getDynamicFieldJson(String parentId0x, String nameType, String nameBcsB64)
            throws IOException {
        ObjectNode v = SuiGraphQlClient.vars();
        v.put("id", parentId0x);
        v.put("type", nameType);
        v.put("bcs", nameBcsB64);
        return parseDynamicField(gql.execute(Q_DYNAMIC_FIELD, v), parentId0x);
    }

    static JsonNode parseDynamicField(JsonNode data, String parentId0x) throws IOException {
        JsonNode obj = data.path("object");
        if (obj.isMissingNode() || obj.isNull()) {
            throw new IOException("getDynamicField: parent " + parentId0x + " not found");
        }
        JsonNode df = obj.path("dynamicField");
        if (df.isMissingNode() || df.isNull()) return null;   // field absent
        JsonNode val = df.path("value");
        String kind = val.path("__typename").asText("");
        if ("MoveValue".equals(kind)) return val.path("json");
        if ("MoveObject".equals(kind)) return val.path("contents").path("json");
        throw new IOException("getDynamicField: unexpected value shape on " + parentId0x + ": " + val);
    }

    public SuiPtbEncoder.ObjectRef pickGasCoin(String sender0x, long minBalance) throws IOException {
        String after = null;
        for (int page = 0; page < MAX_COIN_PAGES; page++) {
            ObjectNode v = SuiGraphQlClient.vars();
            v.put("owner", sender0x);
            v.put("type", SUI_COIN_TYPE);
            if (after == null) v.putNull("after"); else v.put("after", after);
            JsonNode data = gql.execute(Q_COINS, v);
            SuiPtbEncoder.ObjectRef ref = pickFromCoinPage(data, sender0x, minBalance);
            if (ref != null) return ref;
            JsonNode pi = data.path("address").path("objects").path("pageInfo");
            if (!pi.path("hasNextPage").asBoolean(false)) break;
            after = pi.path("endCursor").asText(null);
            if (after == null) break;
        }
        throw new IOException("no gas coin with balance >= " + minBalance + " for " + sender0x);
    }

    /** Pure parser: first coin on the page with balance >= minBalance, else null. */
    static SuiPtbEncoder.ObjectRef pickFromCoinPage(JsonNode data, String sender0x, long minBalance)
            throws IOException {
        JsonNode addr = data.path("address");
        if (addr.isMissingNode() || addr.isNull()) {
            throw new IOException("getCoins: no address data for " + sender0x);
        }
        JsonNode nodes = addr.path("objects").path("nodes");
        if (!nodes.isArray()) {
            throw new IOException("getCoins: no coin list for " + sender0x);
        }
        BigInteger min = BigInteger.valueOf(minBalance);
        for (JsonNode coin : nodes) {
            JsonNode bal = coin.path("contents").path("json").path("balance");
            if (!bal.isTextual() && !bal.isNumber()) {
                throw new IOException("getCoins: coin without balance: " + coin);
            }
            BigInteger balance;
            try {
                balance = new BigInteger(bal.asText().trim());
            } catch (NumberFormatException e) {
                throw new IOException("getCoins: non-numeric balance: " + bal);
            }
            if (balance.compareTo(min) < 0) continue;
            String id = coin.path("address").asText("");
            long version = SuiGraphQlClient.requireLong(coin.path("version"), "coin version");
            String digestB58 = coin.path("digest").asText("");
            if (id.isEmpty() || digestB58.isEmpty()) {
                throw new IOException("getCoins: incomplete coin ref: " + coin);
            }
            return new SuiPtbEncoder.ObjectRef(
                    BcsEncoder.hexTo32(id),
                    version,
                    BcsEncoder.base58Decode(digestB58));
        }
        return null;
    }

    public long getReferenceGasPrice() throws IOException {
        return parseReferenceGasPrice(gql.execute(Q_RGP, null));
    }

    static long parseReferenceGasPrice(JsonNode data) throws IOException {
        JsonNode epoch = data.path("epoch");
        if (epoch.isMissingNode() || epoch.isNull()) {
            throw new IOException("getReferenceGasPrice: no epoch data");
        }
        return SuiGraphQlClient.requireLong(epoch.path("referenceGasPrice"), "referenceGasPrice");
    }
}
