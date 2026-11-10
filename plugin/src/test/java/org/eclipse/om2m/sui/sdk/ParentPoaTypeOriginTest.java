package org.eclipse.om2m.sui.sdk;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpServer;

/**
 * PoA reads after a compatible upgrade, and the v9 PoA owner check.
 *
 * After the v9 upgrade every call goes to the v9 package id, but Move types
 * keep the id of the package that defined them (v8). The ParentPoaKey
 * dynamic-field key must therefore be spelt with the TYPE-ORIGIN id
 * (sui.package.original.id), not sui.package.id: pointing the plugin at v9
 * with the old code made every PoA read come back empty.
 *
 * The end-to-end tests run fetchParentPoa against a local stub of the Sui
 * GraphQL endpoint that answers dynamic-field queries by their exact type tag,
 * so they check the type strings the plugin actually sends.
 */
public class ParentPoaTypeOriginTest {

    static final String V8  = "0x88f0b0f7f3f4feb9a01e166567ca36a49ee149b9d260a0ac5cede95d89e962f1";
    static final String V9  = "0x9999999999999999999999999999999999999999999999999999999999999999";
    static final String CLUSTER = "0xe49d6c5faf37ad48ba1213258f3bf596720f25edd9f1fcf796dc6854dd15602f";
    static final String RPI1 = "0xef9c6271d8c6cc9e1d9707a117f876e7a8679509f141879bc05ae7bcffe1d5f9";
    static final String RPI2 = "0x4be6060abaff0b4b6b7229558887f5f054cbe7d9836ba56eff35d848e13dc1f5";
    static final String POA  = "http://10.25.96.200:8282/";

    private HttpServer server;
    private String url;
    /** dynamic-field type tag -> JSON value (base64 for vector<u8>, string for address). */
    private final Map<String, String> fields = new HashMap<>();
    private String currentParent = RPI1;
    private final List<String> queriedTypes = Collections.synchronizedList(new ArrayList<>());
    private Path keystore;

    @Before
    public void startStub() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/graphql", ex -> {
            JsonNode req;
            try (InputStream in = ex.getRequestBody()) { req = new ObjectMapper().readTree(in); }
            JsonNode vars = req.path("variables");
            String body;
            if (vars.has("type")) {                      // dynamicField query
                String type = vars.path("type").asText();
                queriedTypes.add(type);
                String val = fields.get(type);
                body = "{\"data\":{\"object\":{\"address\":\"" + CLUSTER + "\",\"dynamicField\":"
                     + (val == null ? "null" : "{\"value\":{\"__typename\":\"MoveValue\",\"json\":\"" + val + "\"}}")
                     + "}}}";
            } else {                                     // object contents query (cluster)
                body = "{\"data\":{\"object\":{\"address\":\"" + CLUSTER + "\",\"version\":1,\"digest\":\"x\","
                     + "\"asMoveObject\":{\"contents\":{\"json\":{\"current_parent\":\"" + currentParent
                     + "\",\"epoch\":\"5\",\"lease_expires_ms\":\"1\",\"trust_gate\":\"50\"}}}}}}";
            }
            byte[] b = body.getBytes(StandardCharsets.UTF_8);
            ex.getResponseHeaders().add("Content-Type", "application/json");
            ex.sendResponseHeaders(200, b.length);
            try (OutputStream o = ex.getResponseBody()) { o.write(b); }
        });
        server.start();
        url = "http://127.0.0.1:" + server.getAddress().getPort() + "/graphql";
        keystore = Files.createTempFile("ks", ".json");
        Files.write(keystore, "[]".getBytes(StandardCharsets.UTF_8));
    }

    @After
    public void stopStub() throws IOException {
        server.stop(0);
        Files.deleteIfExists(keystore);
    }

    private static String b64(String s) {
        return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));
    }

    private NativePtbBuilder builder(String callPkg, String typeOrigin) throws IOException {
        NativePtbBuilder.Config c = typeOrigin == null
            ? new NativePtbBuilder.Config(url, callPkg, "0x1", "0x2", "0x3", "0x4", "0x6", 1L, 50L)
            : new NativePtbBuilder.Config(url, callPkg, typeOrigin, "0x1", "0x2", "0x3", "0x4", "0x6", 1L, 50L);
        return new NativePtbBuilder(c, keystore);
    }

    // ---------------------------------------------------------------- config

    @Test
    public void typeOriginDefaultsToThePackageId() throws IOException {
        NativePtbBuilder.Config c = new NativePtbBuilder.Config(url, V8, "0x1", "0x2", "0x3", "0x4", "0x6", 1L, 50L);
        assertArrayEquals(c.packageId, c.typeOriginPackageId);
        NativePtbBuilder.Config blank = new NativePtbBuilder.Config(url, V8, " ", "0x1", "0x2", "0x3", "0x4", "0x6", 1L, 50L);
        assertArrayEquals(blank.packageId, blank.typeOriginPackageId);
    }

    @Test
    public void typeOriginIsKeptSeparateFromTheCallTarget() {
        NativePtbBuilder.Config c = new NativePtbBuilder.Config(url, V9, V8, "0x1", "0x2", "0x3", "0x4", "0x6", 1L, 50L);
        assertEquals(V9, NativePtbBuilder.hex0x(c.packageId));
        assertEquals(V8, NativePtbBuilder.hex0x(c.typeOriginPackageId));
    }

    // ---------------------------------------------------------------- pure helpers

    @Test
    public void typePackagesAreTheOriginThenLegacy() {
        assertArrayEquals(new String[] { V8, NativePtbBuilder.LEGACY_V2_PKG }, NativePtbBuilder.poaTypePackages(V8));
        assertArrayEquals(new String[] { NativePtbBuilder.LEGACY_V2_PKG },
                          NativePtbBuilder.poaTypePackages(NativePtbBuilder.LEGACY_V2_PKG));
    }

    @Test
    public void ownerCheck() {
        assertTrue("no owner field (v8): accept", NativePtbBuilder.acceptPoa(null, RPI1));
        assertTrue("no owner field (v8): accept", NativePtbBuilder.acceptPoa("", RPI1));
        assertTrue("owner is the parent", NativePtbBuilder.acceptPoa(RPI1, RPI1));
        assertTrue("case-insensitive", NativePtbBuilder.acceptPoa(RPI1.toUpperCase().replace("0X", "0x"), RPI1));
        assertFalse("owner was deposed", NativePtbBuilder.acceptPoa(RPI2, RPI1));
        assertFalse("parent unknown", NativePtbBuilder.acceptPoa(RPI2, null));
    }

    // ---------------------------------------------------------------- end to end (stub GraphQL)

    @Test
    public void v8BehaviourIsUnchanged() throws IOException {
        fields.put(V8 + "::failover::ParentPoaKey", b64(POA));          // v8: no owner field
        assertEquals(POA, builder(V8, null).fetchParentPoa(CLUSTER));
        assertTrue(queriedTypes.contains(V8 + "::failover::ParentPoaKey"));
        for (String t : queriedTypes) assertFalse("never spelt with another id: " + t, t.startsWith(V9));
    }

    @Test
    public void afterTheUpgradeTypesUseTheOriginalIdNotTheCallTarget() throws IOException {
        // On-chain after the v9 upgrade: the key type is still the v8 one.
        fields.put(V8 + "::failover::ParentPoaKey", b64(POA));
        assertEquals(POA, builder(V9, V8).fetchParentPoa(CLUSTER));
        for (String t : queriedTypes) assertFalse("type spelt with the call target: " + t, t.startsWith(V9));
    }

    @Test
    public void withoutTheOriginalIdTheUpgradedPluginWouldFindNothing() throws IOException {
        // Documents the bug: call target used as type origin -> wrong tag -> null.
        fields.put(V8 + "::failover::ParentPoaKey", b64(POA));
        assertNull(builder(V9, null).fetchParentPoa(CLUSTER));
    }

    @Test
    public void v9PoaFromTheCurrentParentIsAccepted() throws IOException {
        fields.put(V8 + "::failover::ParentPoaKey", b64(POA));
        fields.put(V8 + "::failover::ParentPoaOwnerKey", RPI1);
        currentParent = RPI1;
        assertEquals(POA, builder(V9, V8).fetchParentPoa(CLUSTER));
        assertTrue(queriedTypes.contains(V8 + "::failover::ParentPoaOwnerKey"));
    }

    @Test
    public void v9PoaFromADeposedParentIsIgnored() throws IOException {
        fields.put(V8 + "::failover::ParentPoaKey", b64("http://10.25.96.201:8282/"));
        fields.put(V8 + "::failover::ParentPoaOwnerKey", RPI2);   // published by rpi2 ...
        currentParent = RPI1;                                      // ... but rpi1 is parent now
        assertNull(builder(V9, V8).fetchParentPoa(CLUSTER));
    }

    @Test
    public void legacyV2TagIsStillTried() throws IOException {
        fields.put(NativePtbBuilder.LEGACY_V2_PKG + "::failover::ParentPoaKey", b64(POA));
        assertEquals(POA, builder(V8, null).fetchParentPoa(CLUSTER));
    }
}
