package org.eclipse.om2m.sui.sdk;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

/**
 * Thin wrapper around the Sui CLI. We chose this over the community
 * Java SDKs because (1) the CLI is officially maintained by Mysten
 * Labs, (2) `sui client ptb` builds atomic PTBs directly, which is
 * exactly what slide 9's "Atomic 6-Step Evaluation" requires, and
 * (3) it avoids fighting with BCS serialisation from Java.
 *
 * <p>This class shells out, captures stdout/stderr, and parses the
 * --json output back to a JsonNode. It is intentionally dumb — the
 * actual PTB construction lives in PtbBuilder.
 */
public final class SuiCli {

    private static final Log LOG = LogFactory.getLog(SuiCli.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final long DEFAULT_TIMEOUT_S = 60;

    private final String cliPath;
    private final String env;

    public SuiCli(String cliPath, String env) {
        this.cliPath = cliPath;
        this.env = env;
    }

    /** Executes the given argv with --json appended; returns parsed JSON. */
    public JsonNode runJson(List<String> argv) throws SuiCliException {
        List<String> full = new ArrayList<>();
        full.add(cliPath);
        full.addAll(argv);
        // Force JSON output for parseability.
        full.add("--json");

        ProcessBuilder pb = new ProcessBuilder(full).redirectErrorStream(false);
        // Make sure the right env is active; the CLI uses the active env
        // from ~/.sui/sui_config unless overridden.
        pb.environment().put("SUI_ENV", env);

        LOG.debug("sui-cli exec: " + String.join(" ", full));

        try {
            Process p = pb.start();
            boolean done = p.waitFor(DEFAULT_TIMEOUT_S, TimeUnit.SECONDS);
            if (!done) {
                p.destroyForcibly();
                throw new SuiCliException("sui CLI timed out after " + DEFAULT_TIMEOUT_S + "s");
            }
            byte[] out = readAll(p.getInputStream());
            byte[] err = readAll(p.getErrorStream());
            int rc = p.exitValue();

            String stdout = new String(out, StandardCharsets.UTF_8);
            String stderr = new String(err, StandardCharsets.UTF_8);

            if (rc != 0) {
                throw new SuiCliException(
                    "sui CLI exited " + rc + ": " + stderr.trim());
            }
            if (stdout.trim().isEmpty()) {
                // Some sub-commands print to stderr even on success.
                return MAPPER.readTree(stderr.trim().isEmpty() ? "{}" : stderr);
            }
            return MAPPER.readTree(stdout);
        } catch (IOException | InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new SuiCliException("sui CLI failed: " + e.getMessage(), e);
        }
    }

    public static final class SuiCliException extends Exception {
        public SuiCliException(String m) { super(m); }
        public SuiCliException(String m, Throwable t) { super(m, t); }
    }

    private static byte[] readAll(java.io.InputStream in) throws java.io.IOException {
        java.io.ByteArrayOutputStream baos = new java.io.ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) baos.write(buf, 0, n);
        return baos.toByteArray();
    }
}
