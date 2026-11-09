package org.eclipse.om2m.sui.trust;

import com.fasterxml.jackson.databind.JsonNode;

import org.eclipse.om2m.sui.sdk.BcsEncoder;
import org.eclipse.om2m.sui.sdk.SuiObjectFetcher;
import org.eclipse.om2m.sui.sdk.SuiPtbEncoder;
import org.eclipse.om2m.sui.sdk.SuiRpcClient;

import java.util.Arrays;
import java.util.Base64;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * B10 — {@link MemberRegistry} backed by the on-chain identity registry.
 *
 * <p>Answers membership by dev-inspecting
 * {@code om2m_access::identity::is_registered(&Registry, address): bool}. There
 * was no existing Java accessor for the registered-node set (the registry's
 * {@code nodes} field is a {@code Table}, so its contents are dynamic fields and
 * are not returned by a plain {@code sui_getObject}); this is the client-side
 * read for it, built on the same public BCS/RPC primitives
 * {@code NativePtbBuilder.readTrustScore} uses. dev-inspect costs no gas and
 * needs no signature.
 *
 * <p>Answers are cached for {@code ttlMs} (default 60 s) because the check runs
 * on the MQTT receive path, which sees one message per peer per tick. On RPC
 * failure the last known answer is reused if we have one; otherwise the node
 * fails <b>closed</b> (not a member), consistent with the engine's
 * assume-breach posture elsewhere (cf. the fail-closed seeding in
 * {@code TrustScoringEngine.scoreTarget}).
 */
final class IdentityRegistryMembers implements MemberRegistry {

    private static final Slf4jStyleLog LOG =
        Slf4jStyleLog.getLogger(IdentityRegistryMembers.class);

    private final String selfAddr;
    private final String registryId;
    private final String packageIdHex;
    private final long   ttlMs;
    private final boolean configured;

    private final SuiObjectFetcher fetcher;
    private final SuiRpcClient rpc;

    /** addr(lowercase) -> cached answer. */
    private final Map<String, Entry> cache = new ConcurrentHashMap<>();

    private static final class Entry {
        final boolean member;
        final long expiresAtMs;
        Entry(boolean member, long expiresAtMs) {
            this.member = member;
            this.expiresAtMs = expiresAtMs;
        }
    }

    IdentityRegistryMembers(String rpcUrl, String packageIdHex, String registryId,
                            String selfAddr, long ttlMs) {
        this.selfAddr = selfAddr;
        this.packageIdHex = packageIdHex;
        this.registryId = registryId;
        this.ttlMs = Math.max(1_000L, ttlMs);
        this.configured = notBlank(rpcUrl) && notBlank(packageIdHex) && notBlank(registryId);
        this.fetcher = configured ? new SuiObjectFetcher(rpcUrl) : null;
        this.rpc = configured ? new SuiRpcClient(rpcUrl) : null;
        if (!configured) {
            LOG.error("[trust] B10 membership check DISABLED-CLOSED: missing sui.rpc.url /"
                    + " sui.package.id / sui.identity.registry.id. No remote observer will be"
                    + " admitted until these are configured.");
        } else {
            LOG.info("[trust] B10 membership via identity::is_registered reg={} ttl={}ms",
                     registryId, this.ttlMs);
        }
    }

    @Override
    public boolean isMember(String addr) {
        if (addr == null || addr.trim().isEmpty()) return false;
        // This node is a member by construction: it holds the keypair the
        // deployment registered, and it is the one asking.
        if (addr.equalsIgnoreCase(selfAddr)) return true;
        if (!configured) return false;

        String key = addr.toLowerCase();
        long now = System.currentTimeMillis();
        Entry cached = cache.get(key);
        if (cached != null && now < cached.expiresAtMs) return cached.member;

        Boolean fresh = queryChain(addr);
        if (fresh == null) {
            // RPC unavailable. Prefer a stale positive/negative over guessing.
            if (cached != null) {
                LOG.debug("[trust] B10 registry read failed for {}; reusing stale answer {}",
                          addr, cached.member);
                return cached.member;
            }
            LOG.warn("[trust] B10 registry read failed for {} and no cached answer;"
                   + " rejecting (fail-closed)", addr);
            return false;
        }
        cache.put(key, new Entry(fresh, now + ttlMs));
        if (!fresh) {
            LOG.warn("[trust] B10 observer {} is NOT in the on-chain identity registry;"
                   + " gossip rejected", addr);
        }
        return fresh;
    }

    /** @return TRUE/FALSE from chain, or null if the read could not be performed. */
    private Boolean queryChain(String addr) {
        try {
            SuiObjectFetcher.ObjectInfo reg = fetcher.getObject(registryId);

            SuiPtbEncoder enc = new SuiPtbEncoder();
            int iReg = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                    new SuiPtbEncoder.SharedRef(
                        BcsEncoder.hexTo32(registryId), reg.version, false)));
            // A BCS address is 32 raw bytes, no length prefix.
            int iAddr = enc.addInput(SuiPtbEncoder.CallArg.pure(BcsEncoder.hexTo32(addr)));

            enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                    BcsEncoder.hexTo32(packageIdHex), "identity", "is_registered",
                    Arrays.asList(SuiPtbEncoder.Arg.input(iReg),
                                  SuiPtbEncoder.Arg.input(iAddr))));

            String kindB64 = Base64.getEncoder().encodeToString(enc.encodeTransactionKind());
            JsonNode result = rpc.devInspectTransactionBlock(selfAddr, kindB64);

            JsonNode bytes = result.path("results").path(0)
                                   .path("returnValues").path(0).path(0);
            if (bytes.isArray() && bytes.size() > 0) {
                // BCS bool: single byte, 0 = false.
                return bytes.get(0).asInt() != 0;
            }
            LOG.warn("[trust] B10 unexpected devInspect shape for {}: {}", addr, result);
            return null;
        } catch (Exception e) {
            LOG.warn("[trust] B10 is_registered({}) failed: {}", addr, e.getMessage());
            return null;
        }
    }

    private static boolean notBlank(String s) {
        return s != null && !s.trim().isEmpty();
    }
}
