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
 * Native RPC implementation of the 6-step access-evaluation PTB.
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
        public final byte[] packageId;
        public final String identityRegistryId;
        public final String trustRegistryId;
        public final String policyRegistryId;
        public final String auditTrailId;
        public final String suiClockId;
        public final long gasBudget;
        public final long minTrustRequired;

        public Config(String rpcUrl, String packageHex,
                      String identityReg, String trustReg, String policyReg,
                      String auditTrail, String suiClock,
                      long gasBudget, long minTrustRequired) {
            this.rpcUrl = rpcUrl;
            this.packageId = BcsEncoder.hexTo32(packageHex);
            this.identityRegistryId = identityReg;
            this.trustRegistryId = trustReg;
            this.policyRegistryId = policyReg;
            this.auditTrailId = auditTrail;
            this.suiClockId = suiClock;
            this.gasBudget = gasBudget;
            this.minTrustRequired = minTrustRequired;
        }
    }

    public static final class Result {
        public final boolean granted;
        public final String digest;
        public final long elapsedMs;
        public final String error;

        Result(boolean granted, String digest, long ms, String err) {
            this.granted = granted;
            this.digest = digest;
            this.elapsedMs = ms;
            this.error = err;
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
     * Submits the 6-step PTB on-chain with cert-wait finality.
     */
    public Result evaluate(String requesterAddress, String tokenObjectId,
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
            SuiPtbEncoder.ObjectRef gasCoin = fetcher.pickGasCoin(requesterAddress, cfg.gasBudget);

            byte[] requesterAddr = BcsEncoder.hexTo32(requesterAddress);

            // Build PTB inputs in this exact order:
            //   0: identity_reg (shared imm)
            //   1: requester (pure address)
            //   2: trust_reg (shared imm)
            //   3: min_trust (pure u64)
            //   4: clock (shared imm)
            //   5: token (owned)
            //   6: resource_id (pure string)
            //   7: requested_op (pure u8)
            //   8: policy_reg (shared imm)
            //   9: audit_trail (shared mut)
            SuiPtbEncoder enc = new SuiPtbEncoder();
            int iIdReg    = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.identityRegistryId), idReg.version, false)));
            int iReq      = enc.addInput(SuiPtbEncoder.CallArg.pure(encAddress(requesterAddr)));
            int iTrustReg = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.trustRegistryId), trustReg.version, false)));
            int iMinTrust = enc.addInput(SuiPtbEncoder.CallArg.pure(encU64(cfg.minTrustRequired)));
            int iClock    = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.suiClockId), clock.version, false)));
            int iToken    = enc.addInput(SuiPtbEncoder.CallArg.ownedObject(
                    new SuiPtbEncoder.ObjectRef(BcsEncoder.hexTo32(tokenObjectId), token.version, token.digestRaw32)));
            int iResId    = enc.addInput(SuiPtbEncoder.CallArg.pure(encString(resourceId)));
            int iOp       = enc.addInput(SuiPtbEncoder.CallArg.pure(encU8(requestedOp)));
            int iPolReg   = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.policyRegistryId), polReg.version, false)));
            int iAudit    = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(BcsEncoder.hexTo32(cfg.auditTrailId), auditTr.version, true)));

            // Commands (6-step PTB)
            //  1: identity::verify(id_reg, requester)
            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "identity", "verify",
                    Arrays.asList(SuiPtbEncoder.Arg.input(iIdReg),
                                  SuiPtbEncoder.Arg.input(iReq))));
            //  2: trust::require_min(trust_reg, requester, min_trust, clock) -> $trust (Result(1))
            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "trust", "require_min",
                    Arrays.asList(SuiPtbEncoder.Arg.input(iTrustReg),
                                  SuiPtbEncoder.Arg.input(iReq),
                                  SuiPtbEncoder.Arg.input(iMinTrust),
                                  SuiPtbEncoder.Arg.input(iClock))));
            //  3: cap_token::validate_for_use(token, res_id, op, clock)
            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "cap_token", "validate_for_use",
                    Arrays.asList(SuiPtbEncoder.Arg.input(iToken),
                                  SuiPtbEncoder.Arg.input(iResId),
                                  SuiPtbEncoder.Arg.input(iOp),
                                  SuiPtbEncoder.Arg.input(iClock))));
            //  4: policy::evaluate(pol_reg, res_id, op, trust=Result(1), clock)
            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "policy", "evaluate",
                    Arrays.asList(SuiPtbEncoder.Arg.input(iPolReg),
                                  SuiPtbEncoder.Arg.input(iResId),
                                  SuiPtbEncoder.Arg.input(iOp),
                                  SuiPtbEncoder.Arg.result(1),
                                  SuiPtbEncoder.Arg.input(iClock))));
            //  5+6: evaluator::decide_and_log(audit, requester, res_id, op, trust, token, clock)
            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    cfg.packageId, "evaluator", "decide_and_log",
                    Arrays.asList(SuiPtbEncoder.Arg.input(iAudit),
                                  SuiPtbEncoder.Arg.input(iReq),
                                  SuiPtbEncoder.Arg.input(iResId),
                                  SuiPtbEncoder.Arg.input(iOp),
                                  SuiPtbEncoder.Arg.result(1),
                                  SuiPtbEncoder.Arg.input(iToken),
                                  SuiPtbEncoder.Arg.input(iClock))));

            LOG.info("PTB DEBUG inputs:");
            LOG.info("  identityReg shared ver=" + idReg.version);
            LOG.info("  trustReg shared ver=" + trustReg.version);
            LOG.info("  polReg shared ver=" + polReg.version);
            LOG.info("  auditTrail shared ver=" + auditTr.version);
            LOG.info("  clock shared ver=" + clock.version);
            LOG.info("  token owned ver=" + token.version + " digest_len=" + (token.digestRaw32 == null ? -1 : token.digestRaw32.length));
            LOG.info("  gasCoin id_len=" + gasCoin.objectId.length + " ver=" + gasCoin.version + " digest_len=" + gasCoin.digest.length);
            LOG.info("  requester len=" + requesterAddr.length);
            LOG.info("  gasPrice=" + gasPrice + " gasBudget=" + cfg.gasBudget);
            byte[] txBytes = enc.encodeTransactionData(
                    requesterAddr,
                    Collections.singletonList(gasCoin),
                    gasPrice,
                    cfg.gasBudget);

            // Dump hex for diff against CLI output
            StringBuilder hex = new StringBuilder();
            for (byte b : txBytes) hex.append(String.format("%02x", b & 0xFF));
            LOG.info("PTB tx_bytes hex (" + txBytes.length + " bytes): " + hex.toString());
            String txB64 = java.util.Base64.getEncoder().encodeToString(txBytes);
            LOG.info("PTB tx_bytes b64: " + txB64);
            String sigB64 = Ed25519Signer.signTransaction(txBytes, kp);

            JsonNode result = rpc.executeTransactionBlock(txB64, Collections.singletonList(sigB64));
            String digest = result.path("digest").asText();
            String status = result.path("effects").path("status").path("status").asText();
            long elapsed = ms(t0);

            if ("success".equals(status)) {
                return new Result(true, digest, elapsed, null);
            }
            String err = result.path("effects").path("status").path("error").asText();
            return new Result(false, digest, elapsed, err);

        } catch (Exception e) {
            return new Result(false, null, ms(t0), e.getMessage());
        }
    }

    // ---------------------------------------------------------------
    //  Trust-Gated Parent Failover claim
    // ---------------------------------------------------------------
    /**
     * Submit failover::claim_parent for this cluster.
     * Inputs: cluster (mut shared), identity_reg, trust_reg, clock (imm shared).
     */
    public Result claimParent(String requesterAddress, String clusterId) {
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
            SuiPtbEncoder.ObjectRef gasCoin = fetcher.pickGasCoin(requesterAddress, cfg.gasBudget);

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
                    java.util.Collections.singletonList(gasCoin),
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
        long t0 = System.nanoTime();
        try {
            Ed25519Signer.Keypair kp = keystore.get(requesterAddress.toLowerCase());
            if (kp == null) kp = keystore.get(requesterAddress);
            if (kp == null) return new Result(false, null, ms(t0), "no keypair for " + requesterAddress);

            SuiObjectFetcher.ObjectInfo cluster = fetcher.getObject(clusterId);
            long gasPrice = fetcher.getReferenceGasPrice();
            SuiPtbEncoder.ObjectRef gasCoin = fetcher.pickGasCoin(requesterAddress, cfg.gasBudget);

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
                java.util.Collections.singletonList(gasCoin),
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
     * Read the current parent's PoA from chain via the Cluster's dynamic field.
     * Returns the URL string or null if no PoA has been set yet.
     */
    public String fetchParentPoa(String clusterId) {
        try {
            LOG.info("[fetchParentPoa] start clusterId=" + clusterId + " rpc=" + cfg.rpcUrl);
            com.fasterxml.jackson.databind.ObjectMapper m =
                new com.fasterxml.jackson.databind.ObjectMapper();
            com.fasterxml.jackson.databind.node.ObjectNode req = m.createObjectNode();
            req.put("jsonrpc", "2.0");
            req.put("id", 1);
            req.put("method", "suix_getDynamicFieldObject");
            com.fasterxml.jackson.databind.node.ArrayNode params = req.putArray("params");
            params.add(clusterId);
            com.fasterxml.jackson.databind.node.ObjectNode key = params.addObject();
            StringBuilder pkgHex = new StringBuilder("0x");
            for (byte b : cfg.packageId) pkgHex.append(String.format("%02x", b & 0xFF));
            // The ParentPoaKey field was originally created under v2 (0x1583a958...)
            // and its on-chain type tag is frozen at that address. v3 calls update
            // the field in place but the tag stays v2.
            String pkgForKey = "0x1583a958b1e6afa8a996dbd0933be1b1d2bdbe01f0c7d04322b9dacb22464699";
            key.put("type", pkgForKey + "::failover::ParentPoaKey");
            com.fasterxml.jackson.databind.node.ObjectNode keyValue = m.createObjectNode();
            keyValue.put("dummy_field", false);
            key.set("value", keyValue);

            java.net.HttpURLConnection conn =
                (java.net.HttpURLConnection) new java.net.URL(cfg.rpcUrl).openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(5000);
            conn.setReadTimeout(5000);
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setDoOutput(true);
            byte[] reqBody = m.writeValueAsBytes(req);
            LOG.info("[fetchParentPoa] request: " + new String(reqBody, java.nio.charset.StandardCharsets.UTF_8));
            conn.getOutputStream().write(reqBody);
            int rc = conn.getResponseCode();
            LOG.info("[fetchParentPoa] http status=" + rc);
            if (rc < 200 || rc >= 300) return null;
            java.io.InputStream in = conn.getInputStream();
            java.io.ByteArrayOutputStream baos = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[8192]; int n;
            while ((n = in.read(buf)) > 0) baos.write(buf, 0, n);
            com.fasterxml.jackson.databind.JsonNode resp = m.readTree(baos.toByteArray());
            LOG.info("[fetchParentPoa] response: " + new String(baos.toByteArray(), java.nio.charset.StandardCharsets.UTF_8).substring(0, Math.min(500, baos.size())));
            // The dynamic field's value is the vector<u8> we wrote.
            // Path: result.data.content.fields.value
            com.fasterxml.jackson.databind.JsonNode v = resp
                .path("result").path("data").path("content").path("fields").path("value");
            LOG.info("[fetchParentPoa] value node: isMissing=" + v.isMissingNode() + " isNull=" + v.isNull() + " isArray=" + v.isArray() + " isTextual=" + v.isTextual());
            if (v.isMissingNode() || v.isNull()) return null;
            // value can be either an array of numeric bytes or a string. Handle both.
            if (v.isArray()) {
                byte[] out = new byte[v.size()];
                for (int i = 0; i < v.size(); i++) out[i] = (byte) v.get(i).asInt();
                return new String(out, java.nio.charset.StandardCharsets.UTF_8);
            }
            if (v.isTextual()) return v.asText();
            return null;
        } catch (Exception e) {
            return null;
        }
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
            SuiPtbEncoder.ObjectRef gasCoin =
                    fetcher.pickGasCoin(submitterAddr, cfg.gasBudget);

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
                    Collections.singletonList(gasCoin),
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

}
