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
 * <p>Registration alone is not membership. The identity registry also holds
 * end devices (ESP32 sensors are registered as {@code ROLE_AE} so the bridge
 * can verify their signed readings against an on-chain key). A device key
 * must never count as a trust observer, so an address is a member only if it
 * is registered <b>and</b> its {@code identity::role_of} is IN-CSE or MN-CSE,
 * the same rule {@code failover::claim_parent}, {@code quorum::assert_eligible}
 * and {@code evaluator::log_deny_batch} enforce on-chain.
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

    /** identity.move role constants (ROLE_IN_CSE, ROLE_MN_CSE). */
    static final int ROLE_IN_CSE = 1;
    static final int ROLE_MN_CSE = 2;

    /** The two chain reads this class needs; null means "could not read". */
    interface ChainReader {
        Boolean isRegistered(String addr);
        Integer roleOf(String addr);
    }

    private final ChainReader chain;

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
        this.chain = configured
            ? new RpcChainReader(new SuiObjectFetcher(rpcUrl), new SuiRpcClient(rpcUrl),
                                 packageIdHex, registryId, selfAddr)
            : null;
        if (!configured) {
            LOG.error("[trust] B10 membership check DISABLED-CLOSED: missing sui.rpc.url /"
                    + " sui.package.id / sui.identity.registry.id. No remote observer will be"
                    + " admitted until these are configured.");
        } else {
            LOG.info("[trust] B10 membership via identity::is_registered reg={} ttl={}ms",
                     registryId, this.ttlMs);
        }
    }

    /** Test seam: same logic over a supplied chain reader. */
    IdentityRegistryMembers(ChainReader chain, String selfAddr, long ttlMs) {
        this.selfAddr = selfAddr;
        this.packageIdHex = "";
        this.registryId = "";
        this.ttlMs = Math.max(1_000L, ttlMs);
        this.configured = chain != null;
        this.chain = chain;
    }

    /** Only middleware nodes may observe; an AE (end device) never does. */
    static boolean isMiddlewareRole(Integer role) {
        return role != null && (role == ROLE_IN_CSE || role == ROLE_MN_CSE);
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
            LOG.warn("[trust] B10 observer {} is not a registered middleware node"
                   + " (IN/MN-CSE) in the on-chain identity registry; gossip rejected", addr);
        }
        return fresh;
    }

    /**
     * @return TRUE iff registered with a middleware role, FALSE if not registered
     *         or registered with another role (e.g. an end device), null if the
     *         chain could not be read.
     */
    private Boolean queryChain(String addr) {
        Boolean reg = chain.isRegistered(addr);
        if (reg == null) return null;
        if (!reg) return Boolean.FALSE;
        Integer role = chain.roleOf(addr);
        if (role == null) return null;
        if (!isMiddlewareRole(role)) {
            LOG.warn("[trust] B10 {} is registered with role {} (not IN/MN-CSE); not an observer",
                     addr, role);
            return Boolean.FALSE;
        }
        return Boolean.TRUE;
    }

    /** dev-inspect reads of identity::is_registered / identity::role_of (free, unsigned). */
    private static final class RpcChainReader implements ChainReader {
        private final SuiObjectFetcher fetcher;
        private final SuiRpcClient rpc;
        private final String packageIdHex, registryId, selfAddr;

        RpcChainReader(SuiObjectFetcher fetcher, SuiRpcClient rpc, String packageIdHex,
                       String registryId, String selfAddr) {
            this.fetcher = fetcher;
            this.rpc = rpc;
            this.packageIdHex = packageIdHex;
            this.registryId = registryId;
            this.selfAddr = selfAddr;
        }

        @Override
        public Boolean isRegistered(String addr) {
            JsonNode b = call("is_registered", addr);
            // BCS bool: single byte, 0 = false.
            return b == null ? null : b.get(0).asInt() != 0;
        }

        @Override
        public Integer roleOf(String addr) {
            JsonNode b = call("role_of", addr);
            // BCS u8: single byte.
            return b == null ? null : b.get(0).asInt();
        }

        /** First return value's BCS bytes, or null on any failure. */
        private JsonNode call(String fn, String addr) {
            try {
                SuiObjectFetcher.ObjectInfo reg = fetcher.getObject(registryId);

                SuiPtbEncoder enc = new SuiPtbEncoder();
                int iReg = enc.addInput(SuiPtbEncoder.CallArg.sharedObject(
                        new SuiPtbEncoder.SharedRef(
                            BcsEncoder.hexTo32(registryId), reg.version, false)));
                // A BCS address is 32 raw bytes, no length prefix.
                int iAddr = enc.addInput(SuiPtbEncoder.CallArg.pure(BcsEncoder.hexTo32(addr)));

                enc.addMoveCall(new SuiPtbEncoder.MoveCall(
                        BcsEncoder.hexTo32(packageIdHex), "identity", fn,
                        Arrays.asList(SuiPtbEncoder.Arg.input(iReg),
                                      SuiPtbEncoder.Arg.input(iAddr))));

                String kindB64 = Base64.getEncoder().encodeToString(enc.encodeTransactionKind());
                JsonNode result = rpc.devInspectTransactionBlock(selfAddr, kindB64);

                JsonNode bytes = result.path("results").path(0)
                                       .path("returnValues").path(0).path(0);
                if (bytes.isArray() && bytes.size() > 0) return bytes;
                LOG.warn("[trust] B10 unexpected devInspect shape for {}({}): {}", fn, addr, result);
                return null;
            } catch (Exception e) {
                LOG.warn("[trust] B10 {}({}) failed: {}", fn, addr, e.getMessage());
                return null;
            }
        }
    }

    private static boolean notBlank(String s) {
        return s != null && !s.trim().isEmpty();
    }
}
