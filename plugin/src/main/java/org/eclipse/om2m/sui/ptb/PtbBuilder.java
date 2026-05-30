package org.eclipse.om2m.sui.ptb;

import com.fasterxml.jackson.databind.JsonNode;

import java.util.ArrayList;
import java.util.List;

import org.eclipse.om2m.sui.config.SuiConfig;
import org.eclipse.om2m.sui.sdk.SuiCli;
import org.eclipse.om2m.sui.sdk.SuiCli.SuiCliException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Builds and submits the atomic 6-step access PTB from slide 9.
 *
 * <p>Mapping from slide 9 to {@code sui client ptb} invocation:
 *
 * <pre>
 *   STEP 1 Identity    : PKG::identity::verify
 *   STEP 2 Trust Score : PKG::trust::require_min       -> $trust
 *   STEP 3 Token       : PKG::cap_token::validate_for_use
 *   STEP 4 Policy      : PKG::policy::evaluate          -> $min_trust
 *   STEP 5 Decision    : implicit — reaching step 6 means GRANTED
 *   STEP 6 Audit Log   : PKG::evaluator::decide_and_log
 * </pre>
 *
 * <p>All six commands ride one PTB. Per Sui semantics, if any aborts
 * the entire transaction rolls back and no state changes — exactly the
 * "Zero TOCTOU window" guarantee on slide 8 Layer 2.
 */
public final class PtbBuilder {

    private static final Logger LOG = LoggerFactory.getLogger(PtbBuilder.class);

    private final SuiConfig cfg;
    private final SuiCli cli;

    public PtbBuilder(SuiConfig cfg, SuiCli cli) {
        this.cfg = cfg;
        this.cli = cli;
    }

    /**
     * Submit the 6-step atomic PTB. Returns true if granted, false if
     * any step aborted.
     */
    public AccessResult evaluate(
        String requesterAddress,
        String tokenObjectId,
        String resourceId,
        byte requestedOp,
        long minTrustRequired
    ) {
        String pkg = cfg.packageId;

        List<String> argv = new ArrayList<>();
        argv.add("client");
        argv.add("ptb");

        // STEP 1 — identity::verify(registry, requester)
        argv.add("--move-call");
        argv.add(pkg + "::identity::verify");
        argv.add("@" + cfg.identityRegistryId);
        argv.add("@" + requesterAddress);

        // STEP 2 — trust::require_min(trust_reg, requester, min_required, clock) -> $trust
        argv.add("--assign");
        argv.add("trust_score");
        argv.add("--move-call");
        argv.add(pkg + "::trust::require_min");
        argv.add("@" + cfg.trustRegistryId);
        argv.add("@" + requesterAddress);
        argv.add(Long.toString(minTrustRequired));
        argv.add("@" + cfg.suiClockId);

        // STEP 3 — cap_token::validate_for_use(token, resource_id, op, clock)
        argv.add("--move-call");
        argv.add(pkg + "::cap_token::validate_for_use");
        argv.add("@" + tokenObjectId);
        argv.add(quoteMoveString(resourceId));
        argv.add(Byte.toString(requestedOp));
        argv.add("@" + cfg.suiClockId);

        // STEP 4 — policy::evaluate(policy_reg, resource_id, op, trust, clock)
        argv.add("--move-call");
        argv.add(pkg + "::policy::evaluate");
        argv.add("@" + cfg.policyRegistryId);
        argv.add(quoteMoveString(resourceId));
        argv.add(Byte.toString(requestedOp));
        argv.add("trust_score");
        argv.add("@" + cfg.suiClockId);

        // STEPS 5 + 6 — evaluator::decide_and_log
        argv.add("--move-call");
        argv.add(pkg + "::evaluator::decide_and_log");
        argv.add("@" + cfg.auditTrailId);
        argv.add("@" + requesterAddress);
        argv.add(quoteMoveString(resourceId));
        argv.add(Byte.toString(requestedOp));
        argv.add("trust_score");
        argv.add("@" + tokenObjectId);
        argv.add("@" + cfg.suiClockId);

        argv.add("--gas-budget");
        argv.add(Long.toString(cfg.gasBudget));

        long t0 = System.nanoTime();
        try {
            JsonNode resp = cli.runJson(argv);
            long elapsedMs = (System.nanoTime() - t0) / 1_000_000L;
            return parsePtbResponse(resp, elapsedMs);
        } catch (SuiCliException e) {
            long elapsedMs = (System.nanoTime() - t0) / 1_000_000L;
            // Any abort from steps 1-4 surfaces here as a non-zero exit.
            // The PTB rolled back; no state changed. We classify this as
            // DENIED and let the caller fire an out-of-band denial log.
            LOG.info("Access PTB aborted in {} ms: {}", elapsedMs, e.getMessage());
            return AccessResult.denied(elapsedMs, e.getMessage());
        }
    }

    /**
     * Out-of-band record of a denied request that never made it into a
     * full 6-step PTB (e.g. token missing, requester unknown). Single
     * tx, single call. Slide 9's audit invariant is maintained: every
     * decision is logged, even if not atomically with the original
     * request (denials don't need atomicity — there's nothing to roll
     * back).
     */
    public void logDenied(
        String requesterAddress,
        String resourceId,
        byte requestedOp,
        long trustAtCheck
    ) {
        List<String> argv = new ArrayList<>();
        argv.add("client");
        argv.add("call");
        argv.add("--package");        argv.add(cfg.packageId);
        argv.add("--module");         argv.add("evaluator");
        argv.add("--function");       argv.add("log_denied");
        argv.add("--args");
        argv.add(cfg.auditTrailId);
        argv.add(requesterAddress);
        argv.add(resourceId);
        argv.add(Byte.toString(requestedOp));
        argv.add(Long.toString(trustAtCheck));
        argv.add(cfg.suiClockId);
        argv.add("--gas-budget");     argv.add(Long.toString(cfg.gasBudget));

        try {
            cli.runJson(argv);
        } catch (SuiCliException e) {
            // Denial logging failures aren't fatal but they're worth a
            // loud log — the audit trail will be incomplete.
            LOG.warn("Failed to record denied access on-chain: {}", e.getMessage());
        }
    }

    /** Reads execution status out of the CLI's JSON response. */
    private AccessResult parsePtbResponse(JsonNode resp, long elapsedMs) {
        JsonNode effects = resp.path("effects");
        JsonNode status = effects.path("status").path("status");

        if ("success".equalsIgnoreCase(status.asText())) {
            String digest = resp.path("digest").asText("");
            return AccessResult.granted(elapsedMs, digest);
        }
        // The "failure" branch carries the abort code in
        // effects.status.error.
        String err = effects.path("status").path("error").asText("unknown abort");
        return AccessResult.denied(elapsedMs, err);
    }

    /** Move CLI expects string arguments as quoted strings. */
    private static String quoteMoveString(String s) {
        // Escape embedded quotes — OM2M URIs shouldn't have them in
        // practice but be safe.
        return "\"" + s.replace("\"", "\\\"") + "\"";
    }

    /** Result of a single access PTB. */
    public static final class AccessResult {
        public final boolean granted;
        public final long elapsedMs;
        public final String digestOrError;

        private AccessResult(boolean granted, long ms, String d) {
            this.granted = granted; this.elapsedMs = ms; this.digestOrError = d;
        }
        static AccessResult granted(long ms, String digest) {
            return new AccessResult(true, ms, digest);
        }
        static AccessResult denied(long ms, String error) {
            return new AccessResult(false, ms, error);
        }
    }
}
