package org.eclipse.om2m.sui.ptb;

import com.fasterxml.jackson.databind.JsonNode;

import java.util.ArrayList;
import java.util.List;

import org.eclipse.om2m.sui.config.SuiConfig;
import org.eclipse.om2m.sui.sdk.SuiCli;
import org.eclipse.om2m.sui.sdk.SuiCli.SuiCliException;
import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

/**
 * Builds and submits the atomic access PTB from slide 9.
 *
 * <p>Mapping from slide 9 to {@code sui client ptb} invocation (v8
 * receipt-chain shape):
 *
 * <pre>
 *   STEP 1 Identity    : PKG::identity::verify            -> r1 (IdentityReceipt)
 *   STEP 2 Trust Score : PKG::trust::require_min   (r1)   -> r2 (TrustReceipt)
 *   STEP 3 Token       : PKG::cap_token::validate_for_use (r2) -> r3 (TokenReceipt)
 *   STEP 4 Policy      : PKG::policy::evaluate    (r3)    -> r4 (PolicyReceipt)
 *   STEP 5 Decision    : implicit — reaching step 6 means GRANTED
 *   STEP 6 Audit Log   : PKG::evaluator::decide_and_log (r4)
 * </pre>
 *
 * <p>All five commands ride one PTB. Per Sui semantics, if any aborts
 * the entire transaction rolls back and no state changes — exactly the
 * "Zero TOCTOU window" guarantee on slide 8 Layer 2.
 *
 * <p><b>v8 security model (A3/A4/A5/A6).</b> Each step now returns a
 * "hot potato" receipt struct (no {@code drop}/{@code store}/{@code copy}/
 * {@code key}) which the next step consumes by value. The requester
 * address, the resource id, the requested op and the trust score are
 * carried inside those receipts instead of being re-supplied as
 * arguments, so none of them can be forged by the caller. Concretely:
 *
 * <ul>
 *   <li>{@code identity::verify} takes no {@code claimed} address — the
 *       requester is {@code tx_context::sender}, i.e. <b>the transaction
 *       signer</b>. {@code TxContext} is implicit in Sui and is NOT a PTB
 *       argument, so nothing is passed for it here.</li>
 *   <li>{@code resource_id} is supplied exactly once (step 2).</li>
 *   <li>{@code requested_op} is supplied exactly once (step 3).</li>
 *   <li>{@code policy::evaluate} reads the trust score itself out of the
 *       TrustRegistry, so the registry object is passed where the old
 *       numeric {@code $trust} intermediate used to go.</li>
 *   <li>{@code evaluator::decide_and_log} no longer takes the CapToken.</li>
 * </ul>
 *
 * <p><b>Deployment consequence:</b> the signer of this PTB must BE the
 * requester and must be registered in the identity registry and own the
 * CapToken, otherwise the PTB aborts with {@code identity::E_NOT_REGISTERED (1)}
 * or {@code cap_token::E_NOT_TOKEN_OWNER (5)}. The CLI path signs with
 * whatever address {@code sui client} currently has active, which is this
 * node's own key — it cannot sign on behalf of another CSE. See the
 * mismatch warning in {@link #evaluate}.
 */
public final class PtbBuilder {

    private static final Log LOG = LogFactory.getLog(PtbBuilder.class);

    private final SuiConfig cfg;
    private final SuiCli cli;

    public PtbBuilder(SuiConfig cfg, SuiCli cli) {
        this.cfg = cfg;
        this.cli = cli;
    }

    /**
     * Submit the atomic access PTB. Returns true if granted, false if
     * any step aborted.
     *
     * @param requesterAddress the node the decision is about. As of v8 this
     *        is NOT passed to any Move call — it is derived on-chain from the
     *        transaction signer. It is retained in the signature (callers in
     *        {@code das/} rely on it) and used only to detect a
     *        signer/requester mismatch before we burn gas.
     */
    public AccessResult evaluate(
        String requesterAddress,
        String tokenObjectId,
        String resourceId,
        byte requestedOp,
        long minTrustRequired
    ) {
        String pkg = cfg.packageId;

        // A3/A4: the requester is now tx_context::sender, i.e. whoever signs
        // this transaction. `sui client ptb` signs with the locally active
        // address (this CSE's own key, cfg.nodeAddress), so a PTB submitted
        // on behalf of a *different* node can no longer succeed. Warn loudly
        // rather than silently producing an E_NOT_REGISTERED / E_NOT_TOKEN_OWNER
        // abort that looks like a policy denial.
        if (requesterAddress != null && cfg.nodeAddress != null
                && !normalizeAddr(requesterAddress).equals(normalizeAddr(cfg.nodeAddress))) {
            LOG.warn("Access PTB requester " + requesterAddress
                     + " != local signing address " + cfg.nodeAddress
                     + " — since the v8 A3/A4 fixes the signer IS the requester, so this"
                     + " PTB will abort (identity::E_NOT_REGISTERED / cap_token::E_NOT_TOKEN_OWNER)."
                     + " Each CSE must sign its own access PTB with its own registered key.");
        }

        List<String> argv = new ArrayList<>();
        argv.add("client");
        argv.add("ptb");

        // STEP 1 — identity::verify(id_reg, ctx) -> r1 : IdentityReceipt
        // `ctx` is implicit in Sui; it is never a PTB argument.
        // NOTE: --assign must appear AFTER the call it captures.
        argv.add("--move-call");
        argv.add(pkg + "::identity::verify");
        argv.add("@" + cfg.identityRegistryId);
        argv.add("--assign");
        argv.add("r1");

        // STEP 2 — trust::require_min(r1, trust_reg, resource_id, min_required, clock)
        //          -> r2 : TrustReceipt
        // resource_id enters the chain here, exactly once.
        argv.add("--move-call");
        argv.add(pkg + "::trust::require_min");
        argv.add("r1");
        argv.add("@" + cfg.trustRegistryId);
        argv.add(quoteMoveString(resourceId));
        argv.add(Long.toString(minTrustRequired));
        argv.add("@" + cfg.suiClockId);
        argv.add("--assign");
        argv.add("r2");

        // STEP 3 — cap_token::validate_for_use(r2, token, requested_op, clock, ctx)
        //          -> r3 : TokenReceipt
        // resource_id is gone (it rides r2); requested_op enters here, once.
        argv.add("--move-call");
        argv.add(pkg + "::cap_token::validate_for_use");
        argv.add("r2");
        argv.add("@" + tokenObjectId);
        argv.add(Byte.toString(requestedOp));
        argv.add("@" + cfg.suiClockId);
        argv.add("--assign");
        argv.add("r3");

        // STEP 4 — policy::evaluate(r3, policy_reg, trust_reg, clock)
        //          -> r4 : PolicyReceipt
        // A5: the old numeric `trust_score` argument is replaced by the
        // TrustRegistry object — the score is read on-chain. trust_reg is
        // therefore referenced a second time here.
        // v10: evaluate_with_device also takes the identity registry (device-bound
        // resources); kept in lock-step with NativePtbBuilder.policyStep.
        argv.add("--move-call");
        if (cfg.policyDeviceBinding) {
            argv.add(pkg + "::policy::evaluate_with_device");
            argv.add("r3");
            argv.add("@" + cfg.policyRegistryId);
            argv.add("@" + cfg.trustRegistryId);
            argv.add("@" + cfg.identityRegistryId);
            argv.add("@" + cfg.suiClockId);
        } else {
            argv.add(pkg + "::policy::evaluate");
            argv.add("r3");
            argv.add("@" + cfg.policyRegistryId);
            argv.add("@" + cfg.trustRegistryId);
            argv.add("@" + cfg.suiClockId);
        }
        argv.add("--assign");
        argv.add("r4");

        // STEPS 5 + 6 — evaluator::decide_and_log(r4, audit_trail, clock)
        // No requester / resource / op / trust / token arguments remain.
        argv.add("--move-call");
        argv.add(pkg + "::evaluator::decide_and_log");
        argv.add("r4");
        argv.add("@" + cfg.auditTrailId);
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
            LOG.info("Access PTB aborted in " + elapsedMs + " ms: " + e.getMessage());
            return AccessResult.denied(elapsedMs, e.getMessage());
        }
    }

    /**
     * Object id of the AuditAdminCap minted to the publisher in
     * {@code audit::init}. Required by {@code evaluator::log_denied_authorized}
     * (A7). {@code SuiConfig} has no field for it yet — until config/ grows
     * one (suggested key {@code sui.audit.admin.cap.id}) it is resolved from
     * the {@code sui.audit.admin.cap.id} system property or the
     * {@code SUI_AUDIT_ADMIN_CAP_ID} environment variable, or injected via
     * {@link #setAuditAdminCapId(String)}.
     */
    private volatile String auditAdminCapId = resolveAuditAdminCapIdFromEnv();

    /** Inject the AuditAdminCap object id used by {@link #logDenied}. */
    public void setAuditAdminCapId(String id) {
        this.auditAdminCapId = (id == null || id.trim().isEmpty()) ? null : id.trim();
    }

    private static String resolveAuditAdminCapIdFromEnv() {
        String v = System.getProperty("sui.audit.admin.cap.id");
        if (v == null || v.trim().isEmpty()) {
            v = System.getenv("SUI_AUDIT_ADMIN_CAP_ID");
        }
        return (v == null || v.trim().isEmpty()) ? null : v.trim();
    }

    /**
     * Out-of-band record of a denied request that never made it into a
     * full access PTB (e.g. token missing, requester unknown). Single
     * tx, single call. Slide 9's audit invariant is maintained: every
     * decision is logged, even if not atomically with the original
     * request (denials don't need atomicity — there's nothing to roll
     * back).
     *
     * <p>A7: {@code evaluator::log_denied} is now {@code public(package)} —
     * unreachable from a transaction. The external entry point is
     * {@code evaluator::log_denied_authorized(&AuditAdminCap, trail,
     * requester, resource_id, requested_op, trust_at_check, clock)}, so the
     * AuditAdminCap object id is prepended to {@code --args} and the signer
     * must own that cap.
     */
    public void logDenied(
        String requesterAddress,
        String resourceId,
        byte requestedOp,
        long trustAtCheck
    ) {
        logDenied(requesterAddress, resourceId, requestedOp, trustAtCheck, auditAdminCapId);
    }

    /** As {@link #logDenied(String, String, byte, long)} with an explicit AuditAdminCap id. */
    public void logDenied(
        String requesterAddress,
        String resourceId,
        byte requestedOp,
        long trustAtCheck,
        String auditAdminCapObjectId
    ) {
        if (auditAdminCapObjectId == null || auditAdminCapObjectId.trim().isEmpty()) {
            // Calling log_denied_authorized without the cap is guaranteed to
            // fail argument resolution, so don't burn gas on it. The audit
            // trail will be missing this denial — say so loudly.
            LOG.warn("Cannot record denied access on-chain: no AuditAdminCap object id"
                     + " configured (set the sui.audit.admin.cap.id system property,"
                     + " the SUI_AUDIT_ADMIN_CAP_ID env var, or call setAuditAdminCapId()).");
            return;
        }

        List<String> argv = new ArrayList<>();
        argv.add("client");
        argv.add("call");
        argv.add("--package");        argv.add(cfg.packageId);
        argv.add("--module");         argv.add("evaluator");
        argv.add("--function");       argv.add("log_denied_authorized");
        argv.add("--args");
        argv.add(auditAdminCapObjectId.trim());
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
            LOG.warn("Failed to record denied access on-chain: " + e.getMessage());
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

    /** Lowercase, 0x-stripped form of a Sui address, for comparison only. */
    private static String normalizeAddr(String a) {
        String s = a.trim().toLowerCase();
        if (s.startsWith("0x")) s = s.substring(2);
        // Left-pad to 64 hex chars so 0x5 and 0x0...05 compare equal.
        while (s.length() < 64) s = "0" + s;
        return s;
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
        public static AccessResult granted(long ms, String digest) {
            return new AccessResult(true, ms, digest);
        }
        public static AccessResult denied(long ms, String error) {
            return new AccessResult(false, ms, error);
        }
    }
}
