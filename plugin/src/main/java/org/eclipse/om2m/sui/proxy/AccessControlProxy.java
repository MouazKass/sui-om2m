package org.eclipse.om2m.sui.proxy;

import org.eclipse.om2m.commons.constants.Operation;
import org.eclipse.om2m.commons.constants.ResponseStatusCode;
import org.eclipse.om2m.commons.resource.RequestPrimitive;
import org.eclipse.om2m.commons.resource.ResponsePrimitive;
import org.eclipse.om2m.sui.config.SuiConfig;
import org.eclipse.om2m.sui.ptb.PtbBuilder;
import org.eclipse.om2m.sui.ptb.PtbBuilder.AccessResult;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * The Access Control Proxy on each OM2M node (slide 9, blue box).
 *
 * <p>Lives inside the CSE as an OSGi service. When the CSE receives a
 * RequestPrimitive bound for a resource that requires Sui-mediated
 * access control, it calls {@link #intercept} before fulfilling the
 * request. The proxy constructs the 6-step PTB and waits for an answer.
 *
 * <p>Token resolution: the proxy keeps an in-memory map of
 * (requester originator, resource URI) -> CapToken object ID. This
 * mapping is populated when the IN-CSE mints a token for a node; the
 * mint event is forwarded to the proxy out-of-band by the deploy
 * script. For the prototype this is fine; a production plugin would
 * scan Sui events from the {@code TokenMinted} stream automatically.
 */
public final class AccessControlProxy {

    private static final Logger LOG = LoggerFactory.getLogger(AccessControlProxy.class);

    private final SuiConfig cfg;
    private final PtbBuilder ptb;

    // (requester originator, resource URI) -> CapToken object ID
    private final Map<TokenKey, String> tokenIndex = new ConcurrentHashMap<>();

    // requester originator -> Sui address
    private final Map<String, String> originatorToAddress = new ConcurrentHashMap<>();

    public AccessControlProxy(SuiConfig cfg, PtbBuilder ptb) {
        this.cfg = cfg;
        this.ptb = ptb;
    }

    /** Register a token for a (requester, resource) pair. */
    public void registerToken(String originator, String resourceUri, String tokenObjectId) {
        tokenIndex.put(new TokenKey(originator, resourceUri), tokenObjectId);
    }

    /** Register a requester's Sui address. */
    public void registerOriginator(String originator, String suiAddress) {
        originatorToAddress.put(originator, suiAddress);
    }

    /**
     * Main entry point — called by the CSE before any access-controlled
     * primitive is fulfilled. Returns null on grant; populates response
     * with ACCESS_DENIED on deny.
     */
    public ResponsePrimitive intercept(RequestPrimitive request) {
        String originator = request.getFrom();
        String resourceUri = request.getTo();
        byte op = mapOperation(request.getOperation());

        // Resolve requester address. If unknown -> immediate denial with
        // out-of-band log.
        String suiAddr = originatorToAddress.get(originator);
        if (suiAddr == null) {
            LOG.info("ACCESS DENY: unknown originator '{}' for resource '{}'", originator, resourceUri);
            return deny(request, "Unregistered originator: " + originator);
        }

        // Resolve token. Missing token -> denial.
        String tokenId = tokenIndex.get(new TokenKey(originator, resourceUri));
        if (tokenId == null) {
            LOG.info("ACCESS DENY: no token for ({}, {})", originator, resourceUri);
            ptb.logDenied(suiAddr, resourceUri, op, 0L);
            return deny(request, "No CapToken issued for this (originator, resource) pair");
        }

        // The policy's min_trust is supplied by config or by an
        // off-chain cache; the on-chain Policy module enforces the
        // canonical value. We pass 0 here and let the chain reject
        // below-threshold trust via step 4.
        long minTrustHint = 0L;

        AccessResult result = ptb.evaluate(suiAddr, tokenId, resourceUri, op, minTrustHint);
        LOG.info(
            "ACCESS {}: orig={} res={} op={} elapsed={}ms detail={}",
            result.granted ? "GRANT" : "DENY",
            originator, resourceUri, op, result.elapsedMs, result.digestOrError);

        if (result.granted) {
            return null; // null = continue with the request
        }
        // Denied via PTB abort. PtbBuilder.evaluate already rolled back;
        // for completeness, fire-and-forget a denied-decision record.
        ptb.logDenied(suiAddr, resourceUri, op, 0L);
        return deny(request, "Access PTB aborted: " + result.digestOrError);
    }

    private static ResponsePrimitive deny(RequestPrimitive req, String reason) {
        ResponsePrimitive resp = new ResponsePrimitive(req);
        resp.setResponseStatusCode(ResponseStatusCode.ACCESS_DENIED);
        resp.setContent(reason);
        return resp;
    }

    /** Map oneM2M Operation enum to the op-code bitmask in cap_token. */
    private static byte mapOperation(Operation operation) {
        if (operation == null) return 1; // default: read
        switch (operation) {
            case RETRIEVE: return 1; // OP_READ
            case CREATE:   return 2; // OP_WRITE
            case UPDATE:   return 2; // OP_WRITE
            case DELETE:   return 4; // OP_DELETE
            case NOTIFY:   return 1; // treat NOTIFY as read for now
            default:       return 1;
        }
    }

    /** Composite key for the token index. */
    private static final class TokenKey {
        final String originator;
        final String resourceUri;
        TokenKey(String o, String r) { this.originator = o; this.resourceUri = r; }
        @Override public boolean equals(Object o) {
            if (!(o instanceof TokenKey)) return false;
            TokenKey k = (TokenKey) o;
            return originator.equals(k.originator) && resourceUri.equals(k.resourceUri);
        }
        @Override public int hashCode() { return 31 * originator.hashCode() + resourceUri.hashCode(); }
    }
}
