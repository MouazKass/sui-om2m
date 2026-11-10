package org.eclipse.om2m.sui.das;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashSet;
import java.util.Set;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * F3: structured, local, tamper-evident record of every DENY.
 *
 * <p>One JSON object per line ({@code ts, originator, address, resource, op,
 * source, reason}), appended to {@code path} and rotated at {@code maxBytes}
 * (keeping {@code keep} old files), so a request flood cannot fill the disk.
 *
 * <p>The log is cut into <em>windows</em>. Each DENY line's exact UTF-8 bytes
 * plus {@code '\n'} are fed into a running SHA-256 for the open window.
 * {@link #closeWindow()} finalises it into a {@link Batch} (window start/end,
 * count, distinct keys, digest) and writes a {@code {"batch":{...}}} marker
 * line, which is not part of any digest. Anyone holding the log can recompute
 * a window's digest from the lines between two markers. The v9 contract
 * anchors exactly that digest on-chain ({@code evaluator::log_deny_batch}), so
 * a later edit to the local log is detectable.
 *
 * <p>Never throws into the access path: I/O failures are logged once and the
 * digest bookkeeping continues.
 */
public final class DenyLog {

    private static final Log LOG = LogFactory.getLog(DenyLog.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();
    /** Saturating bound on the distinct-key set held per window. */
    static final int MAX_DISTINCT_TRACKED = 10_000;

    /** A closed window, ready to be anchored on-chain. */
    public static final class Batch {
        public final long windowStartMs;
        public final long windowEndMs;
        public final long count;
        public final long distinct;
        public final byte[] sha256;

        Batch(long start, long end, long count, long distinct, byte[] sha256) {
            this.windowStartMs = start;
            this.windowEndMs = end;
            this.count = count;
            this.distinct = distinct;
            this.sha256 = sha256;
        }

        public String sha256Hex() { return hex(sha256); }
    }

    private final File file;       // null = digest/batching only, no file
    private final long maxBytes;
    private final int keep;

    private OutputStream out;
    private long written;
    private boolean ioWarned;

    private MessageDigest digest;
    private long windowStartMs = -1;
    private long lastTsMs = -1;
    private long count;
    private final Set<String> distinct = new HashSet<>();
    private long distinctSaturated;

    public DenyLog(String path, long maxBytes, int keep) {
        this.file = (path == null || path.trim().isEmpty()) ? null : new File(path.trim());
        this.maxBytes = Math.max(4096, maxBytes);
        this.keep = Math.max(0, keep);
        this.digest = newDigest();
        if (file != null) written = file.length();
    }

    /** Append one DENY line; also feeds the open window's digest. */
    public synchronized void append(long ts, String originator, String address, String resource,
                                    byte op, String source, String reason) {
        ObjectNode n = MAPPER.createObjectNode();
        n.put("ts", ts);
        n.put("originator", originator);
        n.put("address", address);
        n.put("resource", resource);
        n.put("op", op);
        n.put("source", source);
        n.put("reason", truncate(reason, 300));
        String line;
        try {
            line = MAPPER.writeValueAsString(n);
        } catch (IOException e) {
            line = "{\"ts\":" + ts + ",\"source\":\"" + source + "\"}";
        }
        byte[] bytes = (line + "\n").getBytes(StandardCharsets.UTF_8);

        if (windowStartMs < 0) windowStartMs = ts;
        lastTsMs = Math.max(lastTsMs, ts);
        digest.update(bytes);
        count++;
        String k = originator + "|" + resource + "|" + op;
        if (distinct.size() < MAX_DISTINCT_TRACKED) distinct.add(k);
        else if (!distinct.contains(k)) distinctSaturated++;

        write(bytes);
    }

    /**
     * Close the open window. Returns null if no DENY was recorded in it.
     * {@code endMs} is the flush time and must not be earlier than the last
     * DENY in the window.
     */
    public synchronized Batch closeWindow(long endMs) {
        if (count == 0) return null;
        long end = Math.max(endMs, lastTsMs + 1);
        Batch b = new Batch(windowStartMs, end, count, distinct.size() + distinctSaturated, digest.digest());
        ObjectNode n = MAPPER.createObjectNode();
        ObjectNode bn = n.putObject("batch");
        bn.put("start", b.windowStartMs);
        bn.put("end", b.windowEndMs);
        bn.put("count", b.count);
        bn.put("distinct", b.distinct);
        bn.put("sha256", b.sha256Hex());
        try {
            write((MAPPER.writeValueAsString(n) + "\n").getBytes(StandardCharsets.UTF_8));
        } catch (IOException ignored) { /* marker is advisory */ }
        digest = newDigest();
        windowStartMs = -1;
        lastTsMs = -1;
        count = 0;
        distinct.clear();
        distinctSaturated = 0;
        return b;
    }

    private void write(byte[] bytes) {
        if (file == null) return;
        try {
            if (out == null) {
                File dir = file.getAbsoluteFile().getParentFile();
                if (dir != null && !dir.isDirectory()) dir.mkdirs();
                out = new FileOutputStream(file, true);
                written = file.length();
            }
            if (written + bytes.length > maxBytes) rotate();
            out.write(bytes);
            out.flush();
            written += bytes.length;
        } catch (IOException e) {
            if (!ioWarned) {
                LOG.warn("DENY log write failed (" + file + "): " + e.getMessage()
                         + "; continuing without the local file");
                ioWarned = true;
            }
            closeQuietly();
        }
    }

    private void rotate() throws IOException {
        closeQuietly();
        if (keep == 0) {
            if (!file.delete() && file.exists()) throw new IOException("cannot truncate " + file);
        } else {
            File oldest = new File(file.getPath() + "." + keep);
            if (oldest.exists() && !oldest.delete()) throw new IOException("cannot delete " + oldest);
            for (int i = keep - 1; i >= 1; i--) {
                File f = new File(file.getPath() + "." + i);
                if (f.exists() && !f.renameTo(new File(file.getPath() + "." + (i + 1)))) {
                    throw new IOException("cannot rotate " + f);
                }
            }
            if (file.exists() && !file.renameTo(new File(file.getPath() + ".1"))) {
                throw new IOException("cannot rotate " + file);
            }
        }
        out = new FileOutputStream(file, true);
        written = 0;
    }

    private void closeQuietly() {
        if (out != null) {
            try { out.close(); } catch (IOException ignored) { }
            out = null;
        }
    }

    private static MessageDigest newDigest() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }

    private static String truncate(String s, int max) {
        if (s == null) return "";
        return s.length() <= max ? s : s.substring(0, max) + "...";
    }

    static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(String.format("%02x", x & 0xFF));
        return sb.toString();
    }
}
