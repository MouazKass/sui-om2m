package org.eclipse.om2m.sui.sdk;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import org.junit.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Base64;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.Assert.*;

/**
 * Hermetic tests for the JSON-RPC -> GraphQL adapter. Canned bodies are real
 * responses captured from https://graphql.testnet.sui.io/graphql (2026-11-10),
 * trimmed to the fields the queries request. No network access.
 */
public class SuiGraphQlAdapterTest {

    private static final ObjectMapper M = new ObjectMapper();

    static final String CLUSTER = "0x1b6bc3b4010bc85fa6c021dd1b96e81747716275559b554bf258c7f88a364d38";
    static final String RPI3 = "0x27dacda1bdcb3fb8dc2a4b0d77b420deea5bb43d1047592ddadb19f35764ea10";
    static final String RPI1 = "0xef9c6271d8c6cc9e1d9707a117f876e7a8679509f141879bc05ae7bcffe1d5f9";
    static final String ID_REG = "0xba114043a145ef073bced1e501d537f1cb915295bf633455761a6497957c6664";
    static final String PKG_V7 = "0x56601695204350f97a90cb283da19682aa6fcaeab876ea736060afea40213d43";

    private static JsonNode data(String body) throws IOException {
        return SuiGraphQlClient.parseResponse(200, body.getBytes(StandardCharsets.UTF_8));
    }

    private static String q(String s) { return s.replace('\'', '"'); }

    // ------------------------------------------------------------------
    //  Transport-level failure contract
    // ------------------------------------------------------------------

    @Test
    public void graphQlErrorsArrayThrows() {
        String body = q("{'data':null,'errors':[{'message':'Invalid argument: Gas budget: 0 is lower than min: 1000000',"
            + "'locations':[{'line':1,'column':29}],'path':['simulateTransaction'],'extensions':{'code':'BAD_USER_INPUT'}}]}");
        try {
            data(body);
            fail("errors array must throw");
        } catch (IOException e) {
            assertTrue(e.getMessage(), e.getMessage().contains("Gas budget: 0"));
            assertTrue(e.getMessage(), e.getMessage().contains("BAD_USER_INPUT"));
        }
    }

    @Test
    public void errorsWithPartialDataStillThrows() {
        String body = q("{'data':{'object':{'version':1}},'errors':[{'message':'boom'}]}");
        try { data(body); fail(); } catch (IOException e) { assertTrue(e.getMessage().contains("boom")); }
    }

    @Test
    public void nullDataThrows() {
        try { data("{\"data\":null}"); fail(); } catch (IOException e) { assertTrue(e.getMessage().contains("no data")); }
        try { data("{}"); fail(); } catch (IOException e) { assertTrue(e.getMessage().contains("no data")); }
    }

    @Test
    public void http500Throws() {
        try {
            SuiGraphQlClient.parseResponse(500, "upstream exploded".getBytes(StandardCharsets.UTF_8));
            fail();
        } catch (IOException e) {
            assertTrue(e.getMessage().contains("HTTP 500"));
            assertTrue(e.getMessage().contains("upstream exploded"));
        }
    }

    @Test
    public void nonJsonThrows() {
        try {
            SuiGraphQlClient.parseResponse(200, "<html>".getBytes(StandardCharsets.UTF_8));
            fail();
        } catch (IOException e) { assertTrue(e.getMessage().contains("not JSON")); }
    }

    @Test
    public void requireLongAcceptsNumberAndStringRejectsJunk() throws IOException {
        assertEquals(929489613L, SuiGraphQlClient.requireLong(M.readTree("929489613"), "v"));
        assertEquals(1783361231433L, SuiGraphQlClient.requireLong(M.readTree("\"1783361231433\""), "v"));
        for (String bad : new String[] {"null", "\"abc\"", "true", "{}"}) {
            try { SuiGraphQlClient.requireLong(M.readTree(bad), "v"); fail(bad); } catch (IOException expected) { }
        }
        try { SuiGraphQlClient.requireLong(M.readTree("{}").path("x"), "v"); fail(); } catch (IOException expected) { }
    }

    // ------------------------------------------------------------------
    //  Endpoint resolution
    // ------------------------------------------------------------------

    @Test
    public void endpointResolution() {
        String prev = SuiGraphQlClient.configuredEndpoint();
        try {
            SuiGraphQlClient.setConfiguredEndpoint(null);
            assertEquals("https://graphql.testnet.sui.io/graphql",
                SuiGraphQlClient.resolveEndpoint("https://fullnode.testnet.sui.io:443"));
            assertEquals("https://graphql.mainnet.sui.io/graphql",
                SuiGraphQlClient.resolveEndpoint("https://fullnode.mainnet.sui.io:443"));
            assertEquals("http://my.node:9000/graphql",
                SuiGraphQlClient.resolveEndpoint("http://my.node:9000/graphql"));
            assertEquals(SuiGraphQlClient.DEFAULT_TESTNET_URL, SuiGraphQlClient.resolveEndpoint(null));
            SuiGraphQlClient.setConfiguredEndpoint("http://cfg.example/graphql");
            assertEquals("http://cfg.example/graphql",
                SuiGraphQlClient.resolveEndpoint("https://fullnode.mainnet.sui.io:443"));
            // an explicit GraphQL URL still wins over the process-wide one
            assertEquals("http://my.node:9000/graphql",
                SuiGraphQlClient.resolveEndpoint("http://my.node:9000/graphql"));
        } finally {
            SuiGraphQlClient.setConfiguredEndpoint(prev);
        }
    }

    // ------------------------------------------------------------------
    //  sui_getObject replacement
    // ------------------------------------------------------------------

    static final String CLUSTER_OBJECT = q("{'data':{'object':{'address':'" + CLUSTER + "','version':929489613,"
        + "'digest':'4QpWSHERzvE2E1YpDK1TUCEYotZtCc3a8Kgbw8dyiikv',"
        + "'owner':{'__typename':'Shared','initialSharedVersion':920669421}}}}");

    @Test
    public void sharedObjectUsesInitialSharedVersionNotVersion() throws IOException {
        SuiObjectFetcher.ObjectInfo info = SuiObjectFetcher.parseObjectInfo(data(CLUSTER_OBJECT), CLUSTER);
        assertTrue(info.isShared);
        assertEquals(920669421L, info.version);
        assertNull(info.digestRaw32);
    }

    @Test
    public void ownedObjectUsesVersionAndDigest() throws IOException {
        String body = q("{'data':{'object':{'address':'0x4d36','version':929506746,"
            + "'digest':'5iyLh4Q9dpLBd8TT1sqRgnT3TfRCwdH5FGXd9CwF9SLd',"
            + "'owner':{'__typename':'AddressOwner'}}}}");
        SuiObjectFetcher.ObjectInfo info = SuiObjectFetcher.parseObjectInfo(data(body), "0x4d36");
        assertFalse(info.isShared);
        assertEquals(929506746L, info.version);
        assertEquals(32, info.digestRaw32.length);
    }

    @Test
    public void absentObjectThrowsNotTreatedAsShared() throws IOException {
        JsonNode d = data("{\"data\":{\"object\":null}}");
        try { SuiObjectFetcher.parseObjectInfo(d, "0xdead"); fail(); }
        catch (IOException e) { assertTrue(e.getMessage().contains("not found")); }
        try { SuiObjectFetcher.parseMoveObjectJson(d, "0xdead"); fail(); }
        catch (IOException e) { assertTrue(e.getMessage().contains("not found")); }
    }

    @Test
    public void sharedWithoutInitialVersionThrows() throws IOException {
        JsonNode d = data(q("{'data':{'object':{'version':5,'digest':'x','owner':{'__typename':'Shared','initialSharedVersion':null}}}}"));
        try { SuiObjectFetcher.parseObjectInfo(d, "0x1"); fail(); } catch (IOException expected) { }
    }

    @Test
    public void clusterContentsAsFailoverManagerReadsThem() throws IOException {
        String body = q("{'data':{'object':{'address':'" + CLUSTER + "','version':929489613,'asMoveObject':{'contents':{"
            + "'type':{'repr':'" + PKG_V7 + "::failover::Cluster'},"
            + "'json':{'id':'" + CLUSTER + "','cluster_id':'RUVfNQ==','current_parent':'" + RPI1 + "',"
            + "'lease_expires_ms':'1783361231433','trust_gate':'50','epoch':'8'}}}}}}");
        JsonNode f = SuiObjectFetcher.parseMoveObjectJson(data(body), CLUSTER);
        assertEquals(RPI1, f.path("current_parent").asText(""));
        assertEquals(1783361231433L, SuiGraphQlClient.requireLong(f.path("lease_expires_ms"), "lease"));
        assertEquals("EE_5", new String(Base64.getDecoder().decode(f.path("cluster_id").asText()), StandardCharsets.UTF_8));
    }

    // ------------------------------------------------------------------
    //  suix_getCoins / suix_getReferenceGasPrice replacements
    // ------------------------------------------------------------------

    static final String COIN_PAGE = q("{'data':{'address':{'objects':{'pageInfo':{'hasNextPage':false,'endCursor':'c'},'nodes':["
        + "{'address':'0x4d369e306c239fafee376d9458394a737899bae42d89c26dba01b4cd913a6a5f','version':929506746,"
        + "'digest':'5iyLh4Q9dpLBd8TT1sqRgnT3TfRCwdH5FGXd9CwF9SLd','contents':{'json':{'id':'0x4d36','balance':'1311227128'}}},"
        + "{'address':'0x06f41389077d6b105dd16e833feb8f983e673a2315d13153a7f60a15242263a3','version':349181780,"
        + "'digest':'A4APyytpKAzNhynFXeraXGvBX7NsizezSA2UbUk35299','contents':{'json':{'id':'0x06f4','balance':'1000000000'}}}"
        + "]}}}}");

    @Test
    public void coinPickHonoursMinBalance() throws IOException {
        SuiPtbEncoder.ObjectRef r = SuiObjectFetcher.pickFromCoinPage(data(COIN_PAGE), RPI3, 20_000_000L);
        assertNotNull(r);
        assertArrayEquals(BcsEncoder.hexTo32("0x4d369e306c239fafee376d9458394a737899bae42d89c26dba01b4cd913a6a5f"), r.objectId);
        assertEquals(929506746L, r.version);
        assertEquals(32, r.digest.length);
        assertNull(SuiObjectFetcher.pickFromCoinPage(data(COIN_PAGE), RPI3, 2_000_000_000L));
    }

    @Test
    public void coinPageWithoutAddressThrows() throws IOException {
        try { SuiObjectFetcher.pickFromCoinPage(data("{\"data\":{\"address\":null}}"), RPI3, 1); fail(); }
        catch (IOException expected) { }
    }

    @Test
    public void referenceGasPriceIsBigIntString() throws IOException {
        assertEquals(1000L, SuiObjectFetcher.parseReferenceGasPrice(
            data(q("{'data':{'epoch':{'epochId':1278,'referenceGasPrice':'1000'}}}"))));
        try { SuiObjectFetcher.parseReferenceGasPrice(data("{\"data\":{\"epoch\":null}}")); fail(); }
        catch (IOException expected) { }
    }

    // ------------------------------------------------------------------
    //  suix_getDynamicFieldObject replacement
    // ------------------------------------------------------------------

    @Test
    public void dynamicFieldPresentAbsentAndMissingParent() throws IOException {
        String present = q("{'data':{'object':{'address':'0x69f3','dynamicField':{'value':{'__typename':'MoveValue',"
            + "'json':{'contents':['0x3729b6a50062680a92130a296da242bc0fd833d59d063a2f843209d5dbc86ac2']}}}}}}");
        JsonNode v = SuiObjectFetcher.parseDynamicField(data(present), "0x69f3");
        assertEquals(1, v.path("contents").size());
        assertNull(SuiObjectFetcher.parseDynamicField(
            data(q("{'data':{'object':{'address':'" + CLUSTER + "','dynamicField':null}}}")), CLUSTER));
        try { SuiObjectFetcher.parseDynamicField(data("{\"data\":{\"object\":null}}"), CLUSTER); fail(); }
        catch (IOException e) { assertTrue(e.getMessage().contains("not found")); }
    }

    @Test
    public void parentPoaVecU8IsBase64InGraphQl() throws IOException {
        String url = "http://10.25.96.201:8282";
        String b64 = Base64.getEncoder().encodeToString(url.getBytes(StandardCharsets.UTF_8));
        assertEquals(url, NativePtbBuilder.decodeVecU8String(M.readTree("\"" + b64 + "\"")));
        assertEquals("hi", NativePtbBuilder.decodeVecU8String(M.readTree("[104,105]")));   // legacy shape
        assertNull(NativePtbBuilder.decodeVecU8String(M.readTree("null")));
    }

    // ------------------------------------------------------------------
    //  sui_devInspectTransactionBlock -> simulateTransaction
    // ------------------------------------------------------------------

    /** Exactly the request verified live to return is_registered(rpi3) == true. */
    static final String LIVE_VERIFIED_SIM_TX =
        "AAACAQG6EUBDoUXvBzvO0eUB1Tfxy5FSlb9jNFV2GmSXlXxmZL4+xDYAAAAAAAAgJ9rNob3LP7jcKksNd7Qg3upbtD0QR1kt2tsZ81dk6hAB"
        + "AFZgFpUgQ1D5epDLKD2hloKqb8rquHbqc2Bgr+pAIT1DCGlkZW50aXR5DWlzX3JlZ2lzdGVyZWQAAgEAAAEBACfazaG9yz+43CpLDXe0IN7q"
        + "W7Q9EEdZLdrbGfNXZOoQACfazaG9yz+43CpLDXe0IN7qW7Q9EEdZLdrbGfNXZOoQ6AMAAAAAAACA8PoCAAAAAAA=";

    @Test
    public void simulationTxDataMatchesLiveVerifiedBytes() {
        // Built exactly as IdentityRegistryMembers.queryChain builds it.
        SuiPtbEncoder enc = new SuiPtbEncoder();
        int iReg = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
            new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(ID_REG), 918830782L, false)));
        int iAddr = enc.addInput(SuiPtbEncoder.CallArg.pure(BcsEncoder.hexTo32(RPI3)));
        enc.addMoveCall(new SuiPtbEncoder.MoveCall(BcsEncoder.hexTo32(PKG_V7), "identity", "is_registered",
            Arrays.asList(SuiPtbEncoder.Arg.input(iReg), SuiPtbEncoder.Arg.input(iAddr))));
        byte[] tx = SuiRpcClient.wrapKindForSimulation(enc.encodeTransactionKind(),
            BcsEncoder.hexTo32(RPI3), 1000L, SuiRpcClient.DEV_INSPECT_GAS_BUDGET);
        assertEquals(LIVE_VERIFIED_SIM_TX, Base64.getEncoder().encodeToString(tx));
    }

    @Test
    public void simulationSuccessReshapedToDevInspectReturnValues() throws IOException {
        String body = q("{'data':{'simulateTransaction':{'effects':{'digest':'EaJrghWvue8nduUiWBsafgP5ftPuXYwX2geDT66k6cDg',"
            + "'status':'SUCCESS','executionError':null},"
            + "'outputs':[{'returnValues':[{'value':{'type':{'repr':'bool'},'bcs':'AQ=='}}]}]}}}");
        JsonNode r = SuiRpcClient.reshapeSimulation(data(body));
        // the exact path IdentityRegistryMembers / readTrustScore read
        JsonNode bytes = r.path("results").path(0).path("returnValues").path(0).path(0);
        assertTrue(bytes.isArray());
        assertEquals(1, bytes.size());
        assertEquals(1, bytes.get(0).asInt());
        assertEquals("bool", r.path("results").path(0).path("returnValues").path(0).path(1).asText());
        assertFalse(r.has("error"));

        String f = q("{'data':{'simulateTransaction':{'effects':{'status':'SUCCESS'},"
            + "'outputs':[{'returnValues':[{'value':{'type':{'repr':'bool'},'bcs':'AA=='}}]}]}}}");
        assertEquals(0, SuiRpcClient.reshapeSimulation(data(f))
            .path("results").path(0).path("returnValues").path(0).path(0).get(0).asInt());
    }

    @Test
    public void simulationU64ReturnDecodesLittleEndian() throws IOException {
        // 73 as BCS u64 -> readTrustScore's LE fold must give 73
        String b64 = Base64.getEncoder().encodeToString(new byte[] {73, 0, 0, 0, 0, 0, 0, 0});
        String body = q("{'data':{'simulateTransaction':{'effects':{'status':'SUCCESS'},"
            + "'outputs':[{'returnValues':[{'value':{'type':{'repr':'u64'},'bcs':'" + b64 + "'}}]}]}}}");
        JsonNode bytes = SuiRpcClient.reshapeSimulation(data(body))
            .path("results").path(0).path("returnValues").path(0).path(0);
        long v = 0; int shift = 0;
        for (JsonNode b : bytes) { v |= ((long) b.asInt() & 0xFF) << shift; shift += 8; }
        assertEquals(73L, v);
    }

    @Test
    public void simulationAbortHasErrorAndNoResults() throws IOException {
        String body = q("{'data':{'simulateTransaction':{'effects':{'status':'FAILURE','executionError':{"
            + "'message':'Error in 1st command, from `0x2::dynamic_field::borrow_child_object` (instruction 0), abort code: 1',"
            + "'abortCode':'1','instructionOffset':0,'module':{'name':'dynamic_field','package':{'address':'0x2'}},"
            + "'function':{'name':'borrow_child_object'}}},'outputs':[]}}}");
        JsonNode r = SuiRpcClient.reshapeSimulation(data(body));
        assertFalse(r.has("results"));
        assertEquals("failure", r.path("effects").path("status").path("status").asText());
        assertTrue(r.path("error").asText().contains("abort code: 1"));
        assertTrue(r.path("results").path(0).path("returnValues").path(0).path(0).isMissingNode());
    }

    @Test
    public void simulationMissingBcsThrows() throws IOException {
        String body = q("{'data':{'simulateTransaction':{'effects':{'status':'SUCCESS'},"
            + "'outputs':[{'returnValues':[{'value':null}]}]}}}");
        try { SuiRpcClient.reshapeSimulation(data(body)); fail(); } catch (IOException expected) { }
    }

    // ------------------------------------------------------------------
    //  sui_executeTransactionBlock -> executeTransaction
    // ------------------------------------------------------------------

    @Test
    public void executionSuccessReshaped() throws IOException {
        String body = q("{'data':{'executeTransaction':{'effects':{'digest':'C8EcSPYGa2YUWnJkUEWets564ZDBLkscxRETwr8XBLFv',"
            + "'status':'SUCCESS','executionError':null}}}}");
        JsonNode r = SuiRpcClient.reshapeExecution(data(body));
        assertEquals("C8EcSPYGa2YUWnJkUEWets564ZDBLkscxRETwr8XBLFv", r.path("digest").asText());
        assertEquals("success", r.path("effects").path("status").path("status").asText());
    }

    @Test
    public void executionAbortKeepsDigestAndIsAbortDecoderCompatible() throws IOException {
        String body = q("{'data':{'executeTransaction':{'effects':{'digest':'D1g','status':'FAILURE','executionError':{"
            + "'message':'trust too low','abortCode':'2','instructionOffset':12,"
            + "'module':{'name':'trust','package':{'address':'" + PKG_V7 + "'}},'function':{'name':'require_min'}}}}}}");
        JsonNode r = SuiRpcClient.reshapeExecution(data(body));
        assertEquals("D1g", r.path("digest").asText());
        assertEquals("failure", r.path("effects").path("status").path("status").asText());
        String err = r.path("effects").path("status").path("error").asText();
        // the regexes das.AbortDecoder applies
        Matcher mod = Pattern.compile("name:\\s*Identifier\\(\"(\\w+)\"\\)").matcher(err);
        Matcher code = Pattern.compile("\\},\\s*(\\d+)\\)").matcher(err);
        assertTrue(err, mod.find());
        assertTrue(err, code.find());
        assertEquals("trust", mod.group(1));
        assertEquals("2", code.group(1));
    }

    @Test
    public void executionMissingStatusIsNotSuccess() throws IOException {
        JsonNode r = SuiRpcClient.reshapeExecution(
            data(q("{'data':{'executeTransaction':{'effects':{'digest':'D','status':null}}}}")));
        assertEquals("unknown", r.path("effects").path("status").path("status").asText());
        assertEquals("D", r.path("digest").asText());
    }

    @Test
    public void executionWithoutEffectsThrows() throws IOException {
        try { SuiRpcClient.reshapeExecution(data(q("{'data':{'executeTransaction':{'effects':null}}}"))); fail(); }
        catch (IOException expected) { }
    }

    @Test
    public void nonAbortFailurePassesMessageThrough() {
        JsonNode err = M.createObjectNode().put("message", "InsufficientGas");
        assertEquals("InsufficientGas", SuiRpcClient.formatExecutionError(err));
    }
}
