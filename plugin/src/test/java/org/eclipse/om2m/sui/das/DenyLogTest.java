package org.eclipse.om2m.sui.das;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.List;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

/**
 * F3: every DENY is written as one JSON line, and each window's digest can be
 * recomputed by anyone from the lines between two batch markers. That digest
 * is what v9 anchors on-chain.
 */
public class DenyLogTest {

    @Rule public TemporaryFolder tmp = new TemporaryFolder();
    private static final ObjectMapper M = new ObjectMapper();

    @Test
    public void linesAreStructuredAndTheWindowDigestIsRecomputable() throws Exception {
        File f = new File(tmp.getRoot(), "deny.jsonl");
        DenyLog log = new DenyLog(f.getPath(), 1 << 20, 2);
        log.append(1000, "Csensor-001", "0xabc", "/in-cse/Csui-dac-ae", (byte) 4, "SIMULATED", "cap_token abort 4");
        log.append(1500, "Csensor-001", "0xabc", "/in-cse/Csui-dac-ae", (byte) 4, "CACHED", "cached");
        log.append(1700, "Cx\"quote", null, "/r", (byte) 1, "UNMAPPED", "no Sui mapping");
        DenyLog.Batch b = log.closeWindow(2000);
        assertNotNull(b);
        assertEquals(1000, b.windowStartMs);
        assertEquals(2000, b.windowEndMs);
        assertEquals(3, b.count);
        assertEquals(2, b.distinct);

        List<String> lines = Files.readAllLines(f.toPath(), StandardCharsets.UTF_8);
        assertEquals(4, lines.size());
        JsonNode first = M.readTree(lines.get(0));
        assertEquals(1000, first.path("ts").asLong());
        assertEquals("Csensor-001", first.path("originator").asText());
        assertEquals("0xabc", first.path("address").asText());
        assertEquals("/in-cse/Csui-dac-ae", first.path("resource").asText());
        assertEquals(4, first.path("op").asInt());
        assertEquals("SIMULATED", first.path("source").asText());
        assertEquals("Cx\"quote", M.readTree(lines.get(2)).path("originator").asText());

        // Independent recomputation: SHA-256 over each DENY line + '\n'.
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        for (int i = 0; i < 3; i++) md.update((lines.get(i) + "\n").getBytes(StandardCharsets.UTF_8));
        assertArrayEquals(md.digest(), b.sha256);
        JsonNode marker = M.readTree(lines.get(3)).path("batch");
        assertEquals(b.sha256Hex(), marker.path("sha256").asText());
        assertEquals(3, marker.path("count").asLong());
    }

    @Test
    public void editingALoggedLineChangesTheDigest() throws Exception {
        DenyLog a = new DenyLog(null, 1 << 20, 0);
        DenyLog b = new DenyLog(null, 1 << 20, 0);
        a.append(1, "Cs", "0xa", "/r", (byte) 4, "SIMULATED", "abort");
        b.append(1, "Cs", "0xa", "/r", (byte) 1, "SIMULATED", "abort");
        assertFalse(java.util.Arrays.equals(a.closeWindow(2).sha256, b.closeWindow(2).sha256));
    }

    @Test
    public void anEmptyWindowProducesNoBatchAndWindowsDoNotLeak() {
        DenyLog log = new DenyLog(null, 1 << 20, 0);
        assertNull(log.closeWindow(5));
        log.append(10, "Cs", "0xa", "/r", (byte) 4, "SIMULATED", "abort");
        DenyLog.Batch b1 = log.closeWindow(20);
        log.append(30, "Cs", "0xa", "/r", (byte) 4, "SIMULATED", "abort");
        DenyLog.Batch b2 = log.closeWindow(40);
        assertEquals(1, b2.count);
        assertEquals(30, b2.windowStartMs);
        assertTrue("windows never overlap", b2.windowStartMs >= b1.windowEndMs);
        assertNull(log.closeWindow(50));
    }

    @Test
    public void windowEndIsAfterItsLastDenyEvenIfTheFlushClockLags() {
        DenyLog log = new DenyLog(null, 1 << 20, 0);
        log.append(100, "Cs", "0xa", "/r", (byte) 4, "SIMULATED", "abort");
        DenyLog.Batch b = log.closeWindow(50);
        assertTrue(b.windowStartMs < b.windowEndMs);
    }

    @Test
    public void rotationBoundsDiskUse() throws Exception {
        File f = new File(tmp.getRoot(), "deny.jsonl");
        DenyLog log = new DenyLog(f.getPath(), 4096, 2);
        for (int i = 0; i < 2000; i++) {
            log.append(i, "Cs", "0xa", "/r" + i, (byte) 4, "SIMULATED", "abort");
        }
        assertTrue(f.length() <= 4096);
        assertTrue(new File(f.getPath() + ".1").exists());
        assertTrue(new File(f.getPath() + ".2").exists());
        assertFalse("keep=2 means no third file", new File(f.getPath() + ".3").exists());
        // Digest bookkeeping is unaffected by rotation.
        assertEquals(2000, log.closeWindow(5000).count);
    }

    @Test
    public void anUnwritableLogNeverBreaksTheAccessPath() throws Exception {
        File dirInTheWay = tmp.newFolder("deny.jsonl");     // a directory where the file should be
        DenyLog log = new DenyLog(dirInTheWay.getPath(), 1 << 20, 1);
        log.append(1, "Cs", "0xa", "/r", (byte) 4, "SIMULATED", "abort");
        assertEquals(1, log.closeWindow(2).count);
    }
}
