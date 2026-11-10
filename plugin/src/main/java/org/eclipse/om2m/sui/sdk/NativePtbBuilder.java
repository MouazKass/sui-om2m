package org.eclipse.om2m.sui.sdk;

import com.fasterxml.jackson.databind.JsonNode;

import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

/**
 * Native RPC implementation of the 5-command access-evaluation PTB
 * (identity -> trust -> cap_token -> policy -> evaluator receipt chain).
 * Bypasses the Sui CLI entirely: BCS-encodes the transaction in-process,
 * signs locally, submits to fullnode RPC with WaitForEffectsCert.
 *
 * Measured baseline (curl, testnet):
 *   - CLI shell-out + WaitForLocalExecution:  ~5.7 s
 *   - Native RPC + WaitForEffectsCert:        ~1.1 s
 */
public final class NativePtbBuilder {

    private static final Log LOG = LogFactory.getLog(NativePtbBuilder.class);

    public static final class Config {
        public final String rpcUrl;
        /** Call target: every MoveCall goes to this package. */
        public final byte[] packageId;
        /**
         * Type origin: the package id used to spell Move TYPE names (e.g. the
         * ParentPoaKey dynamic-field key). Equal to packageId until the package
         * is upgraded; after an upgrade it stays the original id.
         */
        public final byte[] typeOriginPackageId;
        public final String identityRegistryId;
        public final String trustRegistryId;
        public final String policyRegistryId;
        public final String auditTrailId;
        public final String suiClockId;
        public final long gasBudget;
        public final long minTrustRequired;
        /** Where gas comes from (sui.gas.source); AUTO unless set. */
        public final GasPlan.Mode gasSource;

        public Config(String rpcUrl, String packageHex,
                      String identityReg, String trustReg, String policyReg,
                      String auditTrail, String suiClock,
                      long gasBudget, long minTrustRequired) {
            this(rpcUrl, packageHex, packageHex, identityReg, trustReg, policyReg,
                 auditTrail, suiClock, gasBudget, minTrustRequired);
        }

        public Config(String rpcUrl, String packageHex, String typeOriginPackageHex,
                      String identityReg, String trustReg, String policyReg,
                      String auditTrail, String suiClock,
                      long gasBudget, long minTrustRequired) {
            this(rpcUrl, packageHex, typeOriginPackageHex, identityReg, trustReg, policyReg,
                 auditTrail, suiClock, gasBudget, minTrustRequired, GasPlan.Mode.AUTO);
        }

        public Config(String rpcUrl, String packageHex, String typeOriginPackageHex,
                      String identityReg, String trustReg, String policyReg,
                      String auditTrail, String suiClock,
                      long gasBudget, long minTrustRequired, GasPlan.Mode gasSource) {
            this.gasSource = gasSource == null ? GasPlan.Mode.AUTO : gasSource;
            this.rpcUrl = rpcUrl;
            this.packageId = BcsEncoder.hexTo32(packageHex);
            this.typeOriginPackageId = BcsEncoder.hexTo32(
                (typeOriginPackageHex == null || typeOriginPackageHex.trim().isEmpty())
                    ? packageHex : typeOriginPackageHex.trim());
            this.identityRegistryId = identityReg;
            this.trustRegistryId = trustReg;
            this.policyRegistryId = policyReg;
            this.auditTrailId = auditTrail;
            this.suiClockId = suiClock;
            this.gasBudget = gasBudget;
            this.minTrustRequired = minTrustRequired;
        }
    }

    /** How a decision was reached; drives the DAS's DENY bookkeeping (F3). */
    public enum Decision {
        /** Executed on-chain and succeeded. */
        GRANT,
        /** The free pre-check executed the exact transaction and it failed (a Move verdict). Nothing paid. */
        DENY_SIMULATED,
        /** Submitted and failed on-chain (paid). Should be rare once the pre-check is on. */
        DENY_EXECUTED,
        /** No verdict: transport/GraphQL/build error, pre-check unavailable. Fail closed, nothing paid. */
        ERROR
    }

    public static final class Result {
        public final boolean granted;
        public final String digest;
        public final long elapsedMs;
        public final String error;
        public final Decision decision;

        Result(boolean granted, String digest, long ms, String err) {
            this(granted, digest, ms, err,
                 granted ? Decision.GRANT : (digest != null && !digest.isEmpty() ? Decision.DENY_EXECUTED : Decision.ERROR));
        }

        public Result(boolean granted, String digest, long ms, String err, Decision decision) {
            this.granted = granted;
            this.digest = digest;
            this.elapsedMs = ms;
            this.error = err;
            this.decision = decision;
        }

        /** True iff a transaction was actually submitted (and therefore paid for). */
        public boolean submitted() {
            return decision == Decision.GRANT || decision == Decision.DENY_EXECUTED;
        }
    }

    /** F3: simulate the access transaction before paying for it. Default on. */
    private volatile boolean precheckEnabled = true;

    public void setPrecheckEnabled(boolean on) { this.precheckEnabled = on; }

    /** The two network operations of a decision, split out so the gating logic is unit-testable. */
    interface TxPath {
        /** Free simulation of the exact unsigned TransactionData; JSON-RPC-shaped status. */
        JsonNode precheck(String txB64) throws IOException;
        /** Sign-and-submit of those same bytes. */
        JsonNode execute(String txB64) throws IOException;
    }

    /**
     * F3: pay only for transactions that the network has just executed, for
     * free, to success.
     *
     * <p>Without this, every DENY was a submitted transaction that aborted
     * on-chain and still paid ~1 mSUI of computation, so a sensor repeating a
     * forbidden request could drain the node's gas. The pre-check executes the
     * very same bytes that would be signed, with every input check enabled.
     * The only differences between the two runs are shared-object state that
     * changed in between, which no originator controls from the DAS side.
     *
     * <ul>
     * <li>pre-check FAILURE (a Move abort: denied) returns DENY_SIMULATED, nothing submitted;</li>
     * <li>pre-check transport/GraphQL error or unknown status returns ERROR, nothing submitted
     *     (fail closed). The message is kept verbatim so a stale-version refusal is still
     *     recognised by {@link #withStaleRetry};</li>
     * <li>pre-check SUCCESS signs and submits the same bytes.</li>
     * </ul>
     */
    static Result precheckThenSubmit(boolean precheck, String txB64, TxPath path, long t0) {
        if (precheck) {
            JsonNode sim;
            try {
                sim = path.precheck(txB64);
            } catch (Exception e) {
                return new Result(false, null, ms(t0),
                        "precheck unavailable (fail closed): " + e.getMessage(), Decision.ERROR);
            }
            JsonNode st = sim.path("effects").path("status");
            String s = st.path("status").asText("");
            if ("failure".equals(s)) {
                return new Result(false, null, ms(t0),
                        "precheck: " + st.path("error").asText("denied"), Decision.DENY_SIMULATED);
            }
            if (!"success".equals(s)) {
                return new Result(false, null, ms(t0),
                        "precheck: unrecognised status (fail closed): " + st.path("error").asText(s), Decision.ERROR);
            }
        }
        try {
            JsonNode result = path.execute(txB64);
            String digest = result.path("digest").asText();
            String status = result.path("effects").path("status").path("status").asText();
            if ("success".equals(status)) {
                return new Result(true, digest, ms(t0), null, Decision.GRANT);
            }
            String err = result.path("effects").path("status").path("error").asText();
            return new Result(false, digest, ms(t0), err,
                    digest == null || digest.isEmpty() ? Decision.ERROR : Decision.DENY_EXECUTED);
        } catch (Exception e) {
            return new Result(false, null, ms(t0), e.getMessage(), Decision.ERROR);
        }
    }

    private final Config cfg;
    private final SuiObjectFetcher fetcher;
    private final SuiRpcClient rpc;
    private final Map<String, Ed25519Signer.Keypair> keystore;

    public NativePtbBuilder(Config cfg, Path keystorePath) throws IOException {
        this.cfg = cfg;
        this.fetcher = new SuiObjectFetcher(cfg.rpcUrl);
        this.rpc = new SuiRpcClient(cfg.rpcUrl);
        this.keystore = Ed25519Signer.loadKeystore(keystorePath);
        LOG.info("NativePtbBuilder ready: " + keystore.size() + " keypair(s) loaded");
    }

    /**
     * Evaluate access for (requesterAddress, resourceId, requestedOp) using tokenObjectId.
     * Submits the access PTB on-chain with cert-wait finality.
     *
     * <p>v8 receipt chain (A3/A4/A5/A6): each command returns a non-droppable
     * receipt struct that the next command consumes by value. On the wire that
     * is {@code Argument::Result(cmdIdx)} — see {@code SuiPtbEncoder.Arg.result}.
     * {@code Result(i)} (not {@code NestedResult}) is correct because every one
     * of these functions returns exactly one value.
     *
     * <pre>
     *   cmd 0  identity::verify(id_reg)                        -> IdentityReceipt
     *   cmd 1  trust::require_min(R0, trust_reg, res_id, min, clock) -> TrustReceipt
     *   cmd 2  cap_token::validate_for_use(R1, token, op, clock)     -> TokenReceipt
     *   cmd 3  policy::evaluate(R2, pol_reg, trust_reg, clock)       -> PolicyReceipt
     *   cmd 4  evaluator::decide_and_log(R3, audit_trail, clock)
     * </pre>
     *
     * <p>{@code &TxContext} / {@code &mut TxContext} parameters are implicit in
     * Sui and are never PTB arguments, so the A3/A4 "ctx added" changes need
     * nothing encoded here.
     *
     * <p>{@code requesterAddress} is no longer a Move argument anywhere: the
     * requester is {@code tx_context::sender}. It is still used to pick the
     * signing keypair and as the transaction sender, which is exactly what
     * makes the new on-chain checks pass.
     */
    public Result evaluate(String requesterAddress, String tokenObjectId,
                           String resourceId, byte requestedOp) {
        return withStaleRetry(() -> evaluateOnce(requesterAddress, tokenObjectId, resourceId, requestedOp));
    }

    private Result evaluateOnce(String requesterAddress, String tokenObjectId,
                           String resourceId, byte requestedOp) {
        long t0 = System.nanoTime();
        try {
            Ed25519Signer.Keypair kp = keystore.get(requesterAddress.toLowerCase());
            if (kp == null) {
                kp = keystore.get(requesterAddress);
            }
            if (kp == null) {
                return new Result(false, null, ms(t0), "no keypair for " + requesterAddress);
            }

            // Fetch on-chain refs we need as PTB inputs
            SuiObjectFetcher.ObjectInfo idReg     = fetcher.getObject(cfg.identityRegistryId);
            SuiObjectFetcher.ObjectInfo trustReg  = fetcher.getObject(cfg.trustRegistryId);
            SuiObjectFetcher.ObjectInfo polReg    = fetcher.getObject(cfg.policyRegistryId);
            SuiObjectFetcher.ObjectInfo auditTr   = fetcher.getObject(cfg.auditTrailId);
            SuiObjectFetcher.ObjectInfo clock     = fetcher.getObject(cfg.suiClockId);
            SuiObjectFetcher.ObjectInfo token     = fetcher.getObject(tokenObjectId);

            long gasPrice = fetcher.getReferenceGasPrice();
            GasPlan gas = fetcher.planGas(requesterAddress, cfg.gasBudget, cfg.gasSource);
            logGasPlan(gas);

            byte[] requesterAddr = BcsEncoder.hexTo32(requesterAddress);

            // Build PTB inputs in this exact order:
            //   0: identity_reg (shared imm)
            //   1: trust_reg (shared imm)   <- referenced twice (cmd 1 and cmd 3)
            //   2: resource_id (pure string)
            //   3: min_trust (pure u64)
            //   4: clock (shared imm)
            //   5: token (owned)
            //   6: requested_op (pure u8)
            //   7: policy_reg (shared imm)
            //   8: audit_trail (shared mut)
            //
            // The old "requester (pure address)" input is GONE: A3/A4 removed
            // every caller-supplied address from these signatures.
            SuiPtbEncoder enc = new SuiPtbEncoder();
            int iIdReg    = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.identityRegistryId), idReg.version, false)));
            int iTrustReg = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.trustRegistryId), trustReg.version, false)));
            int iResId    = enc.addInput(SuiPtbEncoder.CallArg.pure(encString(resourceId)));
            int iMinTrust = enc.addInput(SuiPtbEncoder.CallArg.pure(encU64(cfg.minTrustRequired)));
            int iClock    = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.suiClockId), clock.version, false)));
            int iToken    = enc.addInput(SuiPtbEncoder.CallArg.ownedObject(
                    new SuiPtbEncoder.ObjectRef(BcsEncoder.hexTo32(tokenObjectId), token.version, token.digestRaw32)));
            int iOp       = enc.addInput(SuiPtbEncoder.CallArg.pure(encU8(requestedOp)));
            int iPolReg   = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.policyRegistryId), polReg.version, false)));
            int iAudit    = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.auditTrailId), auditTr.version, true)));

            // Commands — the A6 receipt chain. Command indices are 0-based and
            // Arg.result(i) refers to command i's single return value.
            //  cmd 0: identity::verify(id_reg, &TxContext) -> IdentityReceipt
            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "identity", "verify",
                    Arrays.asList(SuiPtbEncoder.Arg.input(iIdReg))));
            //  cmd 1: trust::require_min(IdentityReceipt=Result(0), trust_reg,
            //                            resource_id, min_trust, clock) -> TrustReceipt
            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "trust", "require_min",
                    Arrays.asList(SuiPtbEncoder.Arg.result(0),
                                  SuiPtbEncoder.Arg.input(iTrustReg),
                                  SuiPtbEncoder.Arg.input(iResId),
                                  SuiPtbEncoder.Arg.input(iMinTrust),
                                  SuiPtbEncoder.Arg.input(iClock))));
            //  cmd 2: cap_token::validate_for_use(TrustReceipt=Result(1), token,
            //                                     requested_op, clock, &TxContext)
            //         -> TokenReceipt   (resource_id arg deleted; it rides the receipt)
            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "cap_token", "validate_for_use",
                    Arrays.asList(SuiPtbEncoder.Arg.result(1),
                                  SuiPtbEncoder.Arg.input(iToken),
                                  SuiPtbEncoder.Arg.input(iOp),
                                  SuiPtbEncoder.Arg.input(iClock))));
            //  cmd 3: policy::evaluate(TokenReceipt=Result(2), pol_reg, trust_reg, clock)
            //         -> PolicyReceipt
            //         A5: the bare `requester_trust: u64` argument is replaced by the
            //         TrustRegistry object — the score is read on-chain via
            //         trust::score_of. resource_id / requested_op args deleted.
            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "policy", "evaluate",
                    Arrays.asList(SuiPtbEncoder.Arg.result(2),
                                  SuiPtbEncoder.Arg.input(iPolReg),
                                  SuiPtbEncoder.Arg.input(iTrustReg),
                                  SuiPtbEncoder.Arg.input(iClock))));
            //  cmd 4 (steps 5+6): evaluator::decide_and_log(PolicyReceipt=Result(3),
            //                                               audit_trail, clock)
            //         The token object argument is gone (token_uses rides the receipt).
            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "evaluator", "decide_and_log",
                    Arrays.asList(SuiPtbEncoder.Arg.result(3),
                                  SuiPtbEncoder.Arg.input(iAudit),
                                  SuiPtbEncoder.Arg.input(iClock))));

            LOG.info("PTB DEBUG inputs:");
            LOG.info("  identityReg shared ver=" + idReg.version);
            LOG.info("  trustReg shared ver=" + trustReg.version);
            LOG.info("  polReg shared ver=" + polReg.version);
            LOG.info("  auditTrail shared ver=" + auditTr.version);
            LOG.info("  clock shared ver=" + clock.version);
            LOG.info("  token owned ver=" + token.version + " digest_len=" + (token.digestRaw32 == null ? -1 : token.digestRaw32.length));
            LOG.info("  gas=" + gas.describe());
            LOG.info("  sender/requester len=" + requesterAddr.length
                     + " (not a Move arg since v8 A3/A4; derived from tx sender)");
            LOG.info("  gasPrice=" + gasPrice + " gasBudget=" + cfg.gasBudget);
            byte[] txBytes = enc.encodeTransactionData(
                    requesterAddr,
                    gas,
                    gasPrice,
                    cfg.gasBudget);

            // Dump hex for diff against CLI output
            StringBuilder hex = new StringBuilder();
            for (byte b : txBytes) hex.append(String.format("%02x", b & 0xFF));
            LOG.info("PTB tx_bytes hex (" + txBytes.length + " bytes): " + hex.toString());
            String txB64 = java.util.Base64.getEncoder().encodeToString(txBytes);
            LOG.info("PTB tx_bytes b64: " + txB64);
            final Ed25519Signer.Keypair signer = kp;
            return precheckThenSubmit(precheckEnabled, txB64, new TxPath() {
                @Override public JsonNode precheck(String b64) throws IOException {
                    return rpc.precheckTransaction(b64);
                }
                @Override public JsonNode execute(String b64) throws IOException {
                    String sigB64 = Ed25519Signer.signTransaction(txBytes, signer);
                    return rpc.executeTransactionBlock(b64, Collections.singletonList(sigB64));
                }
            }, t0);

        } catch (Exception e) {
            return new Result(false, null, ms(t0), e.getMessage());
        }
    }

    // ---------------------------------------------------------------
    //  Stale object versions (GraphQL indexer lag)
    // ---------------------------------------------------------------
    /** Attempts, including the first, for a transaction built on stale versions. */
    static final int STALE_ATTEMPTS = 4;
    static final long STALE_RETRY_BASE_MS = 750L;

    /**
     * True if the network refused the transaction because an input object
     * (typically the gas coin) was read at a version that has since been
     * consumed. Every object ref comes from the GraphQL indexer, which can trail
     * a just-finalised write, so back-to-back transactions from one address
     * (claim -> anchor -> PoA, or two DAS decisions in quick succession) can
     * build on an outdated gas-coin version. Nothing was executed and no gas was
     * charged; rebuilding with fresh reads fixes it.
     */
    /** Address-balance gas is the new path; make every use visible in the log. */
    private static void logGasPlan(GasPlan gas) {
        if (gas.source == GasPlan.Source.ADDRESS_BALANCE) {
            LOG.info("Paying gas from the SUI address balance: " + gas.describe());
        }
    }

    static boolean isStaleObjectVersion(String error) {
        if (error == null) return false;
        return error.contains("needs to be rebuilt")
            || error.contains("unavailable for consumption")
            || error.contains("ObjectVersionUnavailableForConsumption");
    }

    /**
     * Run a build-sign-execute operation, rebuilding it (fresh object reads)
     * after a short, growing delay while it fails on a stale version.
     * Observed live on 2026-11-10: a new parent's first lease anchor failed
     * this way right after its claim, leaving the 1-minute post-claim lease to
     * expire. Any other outcome, success or a real abort, returns immediately.
     */
    static Result withStaleRetry(java.util.function.Supplier<Result> op) {
        Result r = op.get();
        for (int attempt = 1; attempt < STALE_ATTEMPTS && !r.granted && isStaleObjectVersion(r.error); attempt++) {
            try {
                Thread.sleep(STALE_RETRY_BASE_MS * attempt);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                return r;
            }
            LOG.info("Rebuilding transaction after stale object version (attempt " + (attempt + 1) + ")");
            r = op.get();
        }
        return r;
    }

    // ---------------------------------------------------------------
    //  Trust-Gated Parent Failover claim
    // ---------------------------------------------------------------
    /**
     * Submit failover::claim_parent for this cluster.
     * Inputs: cluster (mut shared), identity_reg, trust_reg, clock (imm shared).
     */
    public Result claimParent(String requesterAddress, String clusterId) {
        return withStaleRetry(() -> claimParentOnce(requesterAddress, clusterId));
    }

    private Result claimParentOnce(String requesterAddress, String clusterId) {
        long t0 = System.nanoTime();
        try {
            Ed25519Signer.Keypair kp = keystore.get(requesterAddress);
            if (kp == null) kp = keystore.get(requesterAddress.toLowerCase());
            if (kp == null) {
                return new Result(false, null, ms(t0), "no keypair for " + requesterAddress);
            }

            SuiObjectFetcher.ObjectInfo cluster  = fetcher.getObject(clusterId);
            SuiObjectFetcher.ObjectInfo idReg    = fetcher.getObject(cfg.identityRegistryId);
            SuiObjectFetcher.ObjectInfo trustReg = fetcher.getObject(cfg.trustRegistryId);
            SuiObjectFetcher.ObjectInfo clock    = fetcher.getObject(cfg.suiClockId);
            long gasPrice = fetcher.getReferenceGasPrice();
            GasPlan gas = fetcher.planGas(requesterAddress, cfg.gasBudget, cfg.gasSource);
            logGasPlan(gas);

            byte[] requesterAddr = BcsEncoder.hexTo32(requesterAddress);

            SuiPtbEncoder enc = new SuiPtbEncoder();
            int iCluster = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(clusterId), cluster.version, true)));
            int iId      = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.identityRegistryId), idReg.version, false)));
            int iTrust   = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.trustRegistryId), trustReg.version, false)));
            int iClock   = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.suiClockId), clock.version, false)));

            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "failover", "claim_parent",
                    java.util.Arrays.asList(
                        SuiPtbEncoder.Arg.input(iCluster),
                        SuiPtbEncoder.Arg.input(iId),
                        SuiPtbEncoder.Arg.input(iTrust),
                        SuiPtbEncoder.Arg.input(iClock))));

            byte[] txBytes = enc.encodeTransactionData(
                    requesterAddr,
                    gas,
                    gasPrice,
                    cfg.gasBudget);

            String txB64 = java.util.Base64.getEncoder().encodeToString(txBytes);
            String sigB64 = Ed25519Signer.signTransaction(txBytes, kp);
            JsonNode result = rpc.executeTransactionBlock(txB64, java.util.Collections.singletonList(sigB64));
            String digest = result.path("digest").asText();
            String status = result.path("effects").path("status").path("status").asText();
            long elapsed = ms(t0);
            if ("success".equals(status)) {
                return new Result(true, digest, elapsed, null);
            }
            return new Result(false, digest, elapsed, result.path("effects").path("status").path("error").asText());
        } catch (Exception e) {
            return new Result(false, null, ms(t0), e.getMessage());
        }
    }

    /**
     * Submit failover::renew_lease(cluster, new_lease_ms, clock) as the
     * current parent. This is the lease anchor.
     *
     * <p>It used to go through the sui CLI binary baked into the container
     * (FailoverManager.anchorLease -> cli.runJson). That made the anchor
     * depend on a separate 200 MB binary pinned to an old protocol version
     * (1.73.0 in the image, network at protocol 140), a different transport
     * from every other on-chain write, and a failure mode that is visible
     * only in logs. If the anchor silently fails, the lease expires, a peer
     * claims, and the parent is deposed, so it now uses the same verified
     * native path as {@link #claimParent}.
     *
     * <p>Move enforces {@code sender == cluster.current_parent} and, since
     * A10, {@code new_lease_ms <= MAX_LEASE_MS} (3_600_000).
     */
    public Result renewLease(String requesterAddress, String clusterId, long newLeaseMs) {
        return withStaleRetry(() -> renewLeaseOnce(requesterAddress, clusterId, newLeaseMs));
    }

    private Result renewLeaseOnce(String requesterAddress, String clusterId, long newLeaseMs) {
        long t0 = System.nanoTime();
        try {
            Ed25519Signer.Keypair kp = keystore.get(requesterAddress);
            if (kp == null) kp = keystore.get(requesterAddress.toLowerCase());
            if (kp == null) {
                return new Result(false, null, ms(t0), "no keypair for " + requesterAddress);
            }

            SuiObjectFetcher.ObjectInfo cluster = fetcher.getObject(clusterId);
            SuiObjectFetcher.ObjectInfo clock   = fetcher.getObject(cfg.suiClockId);
            long gasPrice = fetcher.getReferenceGasPrice();
            GasPlan gas = fetcher.planGas(requesterAddress, cfg.gasBudget, cfg.gasSource);
            logGasPlan(gas);

            SuiPtbEncoder enc = new SuiPtbEncoder();
            int iCluster = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(clusterId), cluster.version, true)));
            int iLease   = enc.addInput(SuiPtbEncoder.CallArg.pure(encU64(newLeaseMs)));
            int iClock   = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.suiClockId), clock.version, false)));

            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "failover", "renew_lease",
                    java.util.Arrays.asList(
                        SuiPtbEncoder.Arg.input(iCluster),
                        SuiPtbEncoder.Arg.input(iLease),
                        SuiPtbEncoder.Arg.input(iClock))));

            byte[] txBytes = enc.encodeTransactionData(
                    BcsEncoder.hexTo32(requesterAddress),
                    gas,
                    gasPrice,
                    cfg.gasBudget);

            String txB64 = java.util.Base64.getEncoder().encodeToString(txBytes);
            String sigB64 = Ed25519Signer.signTransaction(txBytes, kp);
            JsonNode result = rpc.executeTransactionBlock(txB64, java.util.Collections.singletonList(sigB64));
            String digest = result.path("digest").asText();
            String status = result.path("effects").path("status").path("status").asText();
            long elapsed = ms(t0);
            if ("success".equals(status)) {
                return new Result(true, digest, elapsed, null);
            }
            return new Result(false, digest, elapsed, result.path("effects").path("status").path("error").asText());
        } catch (Exception e) {
            return new Result(false, null, ms(t0), e.getMessage());
        }
    }

    /**
     * Submit failover::set_parent_poa via native RPC. Used by the new
     * parent immediately after CLAIM ACCEPTED to advertise its HTTP
     * Point-of-Access to followers via the Cluster object's dynamic field.
     */
    public Result setParentPoa(String requesterAddress, String clusterId, String poaUrl) {
        return withStaleRetry(() -> setParentPoaOnce(requesterAddress, clusterId, poaUrl));
    }

    private Result setParentPoaOnce(String requesterAddress, String clusterId, String poaUrl) {
        long t0 = System.nanoTime();
        try {
            Ed25519Signer.Keypair kp = keystore.get(requesterAddress.toLowerCase());
            if (kp == null) kp = keystore.get(requesterAddress);
            if (kp == null) return new Result(false, null, ms(t0), "no keypair for " + requesterAddress);

            SuiObjectFetcher.ObjectInfo cluster = fetcher.getObject(clusterId);
            long gasPrice = fetcher.getReferenceGasPrice();
            GasPlan gas = fetcher.planGas(requesterAddress, cfg.gasBudget, cfg.gasSource);
            logGasPlan(gas);

            byte[] requesterAddr = BcsEncoder.hexTo32(requesterAddress);
            SuiPtbEncoder enc = new SuiPtbEncoder();

            int iCluster = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(clusterId), cluster.version, true)));

            // vector<u8> arg: BCS = uleb128(length) + raw bytes
            byte[] poaBytes = poaUrl.getBytes(java.nio.charset.StandardCharsets.UTF_8);
            BcsEncoder vecEnc = new BcsEncoder();
            vecEnc.writeUleb128(poaBytes.length);
            vecEnc.writeRawBytes(poaBytes);
            int iPoa = enc.addInput(SuiPtbEncoder.CallArg.pure(vecEnc.toBytes()));

            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                cfg.packageId, "failover", "set_parent_poa",
                java.util.Arrays.asList(
                    SuiPtbEncoder.Arg.input(iCluster),
                    SuiPtbEncoder.Arg.input(iPoa))));

            byte[] txBytes = enc.encodeTransactionData(
                requesterAddr,
                gas,
                gasPrice, cfg.gasBudget);

            String txB64  = java.util.Base64.getEncoder().encodeToString(txBytes);
            String sigB64 = Ed25519Signer.signTransaction(txBytes, kp);
            com.fasterxml.jackson.databind.JsonNode resp = rpc.executeTransactionBlock(
                txB64, java.util.Collections.singletonList(sigB64));

            String status = resp.path("effects").path("status").path("status").asText();
            String digest = resp.path("digest").asText();
            long elapsed = ms(t0);
            if ("success".equals(status)) {
                return new Result(true, digest, elapsed, null);
            }
            String err = resp.path("effects").path("status").path("error").asText();
            return new Result(false, digest, elapsed, err);
        } catch (Exception e) {
            return new Result(false, null, ms(t0), e.getMessage());
        }
    }

    /**
     * The ParentPoaKey field on clusters created under the v2 package
     * (0x1583a958...) keeps that frozen type tag even when later versions
     * update it in place, so it is always tried as a fallback.
     */
    static final String LEGACY_V2_PKG =
        "0x1583a958b1e6afa8a996dbd0933be1b1d2bdbe01f0c7d04322b9dacb22464699";
    /** BCS of an empty Move struct key: Move gives it a dummy_field: bool = false. */
    static final String PARENT_POA_KEY_BCS_B64 = "AA==";

    /**
     * Package ids whose {@code ::failover::ParentPoaKey} type tag is tried, in
     * order. Type tags carry the TYPE-ORIGIN package id, never the upgraded
     * call target: after the v9 compatible upgrade the key is still
     * {@code <v8 id>::failover::ParentPoaKey}. Pure, unit-tested.
     */
    static String[] poaTypePackages(String typeOrigin0x) {
        return typeOrigin0x.equalsIgnoreCase(LEGACY_V2_PKG)
            ? new String[] { LEGACY_V2_PKG }
            : new String[] { typeOrigin0x, LEGACY_V2_PKG };
    }

    /**
     * v9 (F2): set_parent_poa also records who published the PoA under
     * {@code ParentPoaOwnerKey}, and claim_parent clears both. A PoA whose
     * recorded owner is not the cluster's current parent belongs to a deposed
     * parent and must be ignored. No owner field (v8, or a v9 cluster whose PoA
     * was written before the upgrade) means "no owner information": today's
     * behaviour, accept. Pure, unit-tested.
     */
    static boolean acceptPoa(String owner0x, String currentParent0x) {
        if (owner0x == null || owner0x.isEmpty()) return true;
        return currentParent0x != null && owner0x.equalsIgnoreCase(currentParent0x);
    }

    static String hex0x(byte[] id32) {
        StringBuilder h = new StringBuilder("0x");
        for (byte b : id32) h.append(String.format("%02x", b & 0xFF));
        return h.toString();
    }

    /**
     * Read the current parent's PoA from the Cluster's dynamic field. Returns
     * the URL, or null if none is set, it belongs to a deposed parent (v9
     * owner check), or the read failed.
     */
    public String fetchParentPoa(String clusterId) {
        try {
            LOG.info("[fetchParentPoa] start clusterId=" + clusterId + " graphql=" + fetcher.endpoint());
            for (String pkg : poaTypePackages(hex0x(cfg.typeOriginPackageId))) {
                JsonNode v = fetcher.getDynamicFieldJson(
                    clusterId, pkg + "::failover::ParentPoaKey", PARENT_POA_KEY_BCS_B64);
                if (v == null) continue;               // no field under this tag
                String poa = decodeVecU8String(v);
                // Owner key lives in the same (type-origin) package as ParentPoaKey.
                // Absent on v8: GraphQL returns a null dynamicField, nothing changes.
                JsonNode o = fetcher.getDynamicFieldJson(
                    clusterId, pkg + "::failover::ParentPoaOwnerKey", PARENT_POA_KEY_BCS_B64);
                if (o != null && !o.isNull()) {
                    String owner = o.asText("");
                    String parent = fetcher.getMoveObjectJson(clusterId).path("current_parent").asText("");
                    if (!acceptPoa(owner, parent)) {
                        LOG.info("[fetchParentPoa] ignoring PoA " + poa + ": published by " + owner
                                 + ", current parent is " + parent);
                        return null;
                    }
                }
                LOG.info("[fetchParentPoa] found under " + pkg + ": " + poa);
                return poa;
            }
            LOG.info("[fetchParentPoa] no ParentPoaKey field on " + clusterId);
            return null;
        } catch (Exception e) {
            LOG.warn("[fetchParentPoa] read failed for " + clusterId + ": " + e.getMessage());
            return null;
        }
    }

    /**
     * Decode a {@code vector<u8>} holding UTF-8. GraphQL renders vector&lt;u8&gt;
     * as base64 (JSON-RPC used a numeric array); both are accepted.
     */
    static String decodeVecU8String(JsonNode v) {
        if (v == null || v.isMissingNode() || v.isNull()) return null;
        if (v.isArray()) {
            byte[] out = new byte[v.size()];
            for (int i = 0; i < v.size(); i++) out[i] = (byte) v.get(i).asInt();
            return new String(out, java.nio.charset.StandardCharsets.UTF_8);
        }
        if (v.isTextual()) {
            byte[] raw = java.util.Base64.getDecoder().decode(v.asText());
            return new String(raw, java.nio.charset.StandardCharsets.UTF_8);
        }
        return null;
    }

    // ---- BCS pre-encoding for Pure args ----
    // Sui Pure args are BCS-encoded inside the Vec<u8> wrapper.

    private static byte[] encAddress(byte[] addr32) {
        // address is 32 raw bytes, no length prefix
        return addr32;
    }

    private static byte[] encU8(byte v) {
        return new byte[] { v };
    }

    private static byte[] encU64(long v) {
        byte[] b = new byte[8];
        for (int i = 0; i < 8; i++) b[i] = (byte) ((v >>> (8 * i)) & 0xFF);
        return b;
    }

    private static byte[] encString(String s) {
        byte[] utf = s.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        BcsEncoder e = new BcsEncoder();
        e.writeUleb128(utf.length);
        e.writeRawBytes(utf);
        return e.toBytes();
    }

    private static long ms(long t0) {
        return (System.nanoTime() - t0) / 1_000_000L;
    }

    /**
     * Read a node's current on-chain trust score via dev-inspect of
     * trust::score_of(&TrustRegistry, address, &Clock). Returns u64, or -1 on failure.
     */
    public long readTrustScore(String targetAddr) {
        try {
            SuiObjectFetcher.ObjectInfo trustReg = fetcher.getObject(cfg.trustRegistryId);
            SuiObjectFetcher.ObjectInfo clock    = fetcher.getObject(cfg.suiClockId);

            SuiPtbEncoder enc = new SuiPtbEncoder();
            int iTrustReg = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(
                        BcsEncoder.hexTo32(cfg.trustRegistryId), trustReg.version, false)));
            int iTarget   = enc.addInput(SuiPtbEncoder.CallArg.pure(
                    encAddress(BcsEncoder.hexTo32(targetAddr))));
            int iClock    = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(
                        BcsEncoder.hexTo32(cfg.suiClockId), clock.version, false)));

            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "trust", "score_of",
                    Arrays.asList(SuiPtbEncoder.Arg.input(iTrustReg),
                                  SuiPtbEncoder.Arg.input(iTarget),
                                  SuiPtbEncoder.Arg.input(iClock))));

            String kindB64 = java.util.Base64.getEncoder()
                    .encodeToString(enc.encodeTransactionKind());

            String senderHex = keystore.keySet().iterator().next();
            JsonNode result = rpc.devInspectTransactionBlock(senderHex, kindB64);

            JsonNode bytes = result.path("results").path(0)
                                   .path("returnValues").path(0).path(0);
            if (bytes.isArray() && bytes.size() > 0) {
                long v = 0; int shift = 0;
                for (JsonNode b : bytes) { v |= ((long) b.asInt() & 0xFF) << shift; shift += 8; }
                return v;
            }
            LOG.warn("readTrustScore: unexpected devInspect shape for " + targetAddr
                     + " resp=" + result.toString());
        } catch (Exception e) {
            LOG.warn("readTrustScore failed for " + targetAddr + ": " + e.getMessage());
        }
        return -1L;
    }

    /**
     * Submit one trust::increase/decrease for target, authorised by this node's AdminCap.
     * Entry (confirm against sources/trust.move):
     *   increase(cap: &AdminCap, reg: &mut TrustRegistry, target: address, magnitude: u64, clock: &Clock)
     *   decrease(...) same shape
     */
    public Result submitTrustDelta(String submitterAddr, String targetAddr,
                                   long magnitude, boolean increase,
                                   String adminCapId) {
        return withStaleRetry(() -> submitTrustDeltaOnce(submitterAddr, targetAddr, magnitude, increase, adminCapId));
    }

    private Result submitTrustDeltaOnce(String submitterAddr, String targetAddr,
                                   long magnitude, boolean increase,
                                   String adminCapId) {
        long t0 = System.nanoTime();
        try {
            Ed25519Signer.Keypair kp = keystore.get(submitterAddr.toLowerCase());
            if (kp == null) kp = keystore.get(submitterAddr);
            if (kp == null) {
                return new Result(false, null, ms(t0),
                        "no keypair for submitter " + submitterAddr);
            }

            SuiObjectFetcher.ObjectInfo cap      = fetcher.getObject(adminCapId);
            SuiObjectFetcher.ObjectInfo trustReg = fetcher.getObject(cfg.trustRegistryId);
            SuiObjectFetcher.ObjectInfo clock    = fetcher.getObject(cfg.suiClockId);

            long gasPrice = fetcher.getReferenceGasPrice();
            GasPlan gas = fetcher.planGas(submitterAddr, cfg.gasBudget, cfg.gasSource);
            logGasPlan(gas);

            byte[] submitterAddrBytes = BcsEncoder.hexTo32(submitterAddr);
            String fn = increase ? "increase_guarded" : "decrease_guarded";

            SuiPtbEncoder enc = new SuiPtbEncoder();
            int iCap   = enc.addInput(SuiPtbEncoder.CallArg.ownedObject(
                    new SuiPtbEncoder.ObjectRef(
                        BcsEncoder.hexTo32(adminCapId), cap.version, cap.digestRaw32)));
            int iReg   = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(
                        BcsEncoder.hexTo32(cfg.trustRegistryId), trustReg.version, true)));
            int iTgt   = enc.addInput(SuiPtbEncoder.CallArg.pure(
                    encAddress(BcsEncoder.hexTo32(targetAddr))));
            int iMag   = enc.addInput(SuiPtbEncoder.CallArg.pure(encU64(magnitude)));
            int iClock = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(
                        BcsEncoder.hexTo32(cfg.suiClockId), clock.version, false)));

            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "trust", fn,
                    Arrays.asList(SuiPtbEncoder.Arg.input(iCap),
                                  SuiPtbEncoder.Arg.input(iReg),
                                  SuiPtbEncoder.Arg.input(iTgt),
                                  SuiPtbEncoder.Arg.input(iMag),
                                  SuiPtbEncoder.Arg.input(iClock))));

            byte[] txBytes = enc.encodeTransactionData(
                    submitterAddrBytes,
                    gas,
                    gasPrice,
                    cfg.gasBudget);

            String txB64  = java.util.Base64.getEncoder().encodeToString(txBytes);
            String sigB64 = Ed25519Signer.signTransaction(txBytes, kp);

            JsonNode result = rpc.executeTransactionBlock(
                    txB64, Collections.singletonList(sigB64));
            String digest = result.path("digest").asText(null);
            String status = result.path("effects").path("status").path("status").asText("");
            if ("success".equals(status)) {
                return new Result(true, digest, ms(t0), null);
            }
            return new Result(false, digest, ms(t0),
                    result.path("effects").path("status").path("error").asText("?"));
        } catch (Exception e) {
            return new Result(false, null, ms(t0), e.getMessage());
        }
    }

    /**
     * v9 (F3): anchor one window of the local DENY log on-chain.
     *
     * <pre>
     *   cmd 0  identity::verify(id_reg)                                 -> IdentityReceipt
     *   cmd 1  evaluator::log_deny_batch(R0, id_reg, node_cap, trust_reg, audit_trail,
     *                                    window_start_ms, window_end_ms, deny_count,
     *                                    distinct_keys, digest, clock)
     * </pre>
     *
     * The function exists only in the v9 package; on v8 the call aborts at the
     * pre-check (free), which is why the flusher stays behind a config flag that
     * is off on v8. Pre-checked like every decision, so a batch the contract
     * would refuse (too soon, overlapping window) is never paid for.
     */
    public Result logDenyBatch(String nodeAddr, String adminCapId, long windowStartMs, long windowEndMs,
                               long denyCount, long distinctKeys, byte[] sha256) {
        return withStaleRetry(() -> logDenyBatchOnce(nodeAddr, adminCapId, windowStartMs, windowEndMs,
                                                     denyCount, distinctKeys, sha256));
    }

    private Result logDenyBatchOnce(String nodeAddr, String adminCapId, long windowStartMs, long windowEndMs,
                                    long denyCount, long distinctKeys, byte[] sha256) {
        long t0 = System.nanoTime();
        try {
            Ed25519Signer.Keypair kp = keystore.get(nodeAddr.toLowerCase());
            if (kp == null) kp = keystore.get(nodeAddr);
            if (kp == null) return new Result(false, null, ms(t0), "no keypair for " + nodeAddr);

            SuiObjectFetcher.ObjectInfo idReg    = fetcher.getObject(cfg.identityRegistryId);
            SuiObjectFetcher.ObjectInfo cap      = fetcher.getObject(adminCapId);
            SuiObjectFetcher.ObjectInfo trustReg = fetcher.getObject(cfg.trustRegistryId);
            SuiObjectFetcher.ObjectInfo auditTr  = fetcher.getObject(cfg.auditTrailId);
            SuiObjectFetcher.ObjectInfo clock    = fetcher.getObject(cfg.suiClockId);
            long gasPrice = fetcher.getReferenceGasPrice();
            GasPlan gas = fetcher.planGas(nodeAddr, cfg.gasBudget, cfg.gasSource);
            logGasPlan(gas);

            SuiPtbEncoder enc = new SuiPtbEncoder();
            int iIdReg = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.identityRegistryId), idReg.version, false)));
            int iCap   = enc.addInput(SuiPtbEncoder.CallArg.ownedObject(
                    new SuiPtbEncoder.ObjectRef(BcsEncoder.hexTo32(adminCapId), cap.version, cap.digestRaw32)));
            int iTrust = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.trustRegistryId), trustReg.version, false)));
            int iAudit = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.auditTrailId), auditTr.version, true)));
            int iStart = enc.addInput(SuiPtbEncoder.CallArg.pure(encU64(windowStartMs)));
            int iEnd   = enc.addInput(SuiPtbEncoder.CallArg.pure(encU64(windowEndMs)));
            int iCount = enc.addInput(SuiPtbEncoder.CallArg.pure(encU64(denyCount)));
            int iDist  = enc.addInput(SuiPtbEncoder.CallArg.pure(encU64(distinctKeys)));
            int iDig   = enc.addInput(SuiPtbEncoder.CallArg.pure(encBytes(sha256)));
            int iClock = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.suiClockId), clock.version, false)));

            enc.addMoveCall(new SuiPtbEncoder.MoveCall(cfg.packageId, "identity", "verify",
                    Arrays.asList(SuiPtbEncoder.Arg.input(iIdReg))));
            enc.addMoveCall(new SuiPtbEncoder.MoveCall(cfg.packageId, "evaluator", "log_deny_batch",
                    Arrays.asList(SuiPtbEncoder.Arg.result(0),
                                  SuiPtbEncoder.Arg.input(iIdReg),
                                  SuiPtbEncoder.Arg.input(iCap),
                                  SuiPtbEncoder.Arg.input(iTrust),
                                  SuiPtbEncoder.Arg.input(iAudit),
                                  SuiPtbEncoder.Arg.input(iStart),
                                  SuiPtbEncoder.Arg.input(iEnd),
                                  SuiPtbEncoder.Arg.input(iCount),
                                  SuiPtbEncoder.Arg.input(iDist),
                                  SuiPtbEncoder.Arg.input(iDig),
                                  SuiPtbEncoder.Arg.input(iClock))));

            final byte[] txBytes = enc.encodeTransactionData(BcsEncoder.hexTo32(nodeAddr),
                    gas, gasPrice, cfg.gasBudget);
            String txB64 = java.util.Base64.getEncoder().encodeToString(txBytes);
            final Ed25519Signer.Keypair signer = kp;
            return precheckThenSubmit(true, txB64, new TxPath() {
                @Override public JsonNode precheck(String b64) throws IOException {
                    return rpc.precheckTransaction(b64);
                }
                @Override public JsonNode execute(String b64) throws IOException {
                    return rpc.executeTransactionBlock(b64,
                            Collections.singletonList(Ed25519Signer.signTransaction(txBytes, signer)));
                }
            }, t0);
        } catch (Exception e) {
            return new Result(false, null, ms(t0), e.getMessage());
        }
    }

    /** BCS vector&lt;u8&gt;: ULEB128 length then the raw bytes. */
    static byte[] encBytes(byte[] b) {
        BcsEncoder e = new BcsEncoder();
        e.writeUleb128(b.length);
        e.writeRawBytes(b);
        return e.toBytes();
    }

}
