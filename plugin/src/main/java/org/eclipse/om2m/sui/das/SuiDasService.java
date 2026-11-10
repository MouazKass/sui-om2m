package org.eclipse.om2m.sui.das;

import java.math.BigInteger;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

import org.eclipse.om2m.commons.constants.Operation;
import org.eclipse.om2m.commons.constants.ResponseStatusCode;
import org.eclipse.om2m.commons.constants.SecurityInfoType;
import org.eclipse.om2m.commons.resource.AccessControlRule;
import org.eclipse.om2m.commons.resource.DynAuthDasRequest;
import org.eclipse.om2m.commons.resource.DynAuthDasResponse;
import org.eclipse.om2m.commons.resource.DynAuthDasResponse.DynamicACPInfo;
import org.eclipse.om2m.commons.resource.RequestPrimitive;
import org.eclipse.om2m.commons.resource.ResponsePrimitive;
import org.eclipse.om2m.commons.resource.SecurityInfo;
import org.eclipse.om2m.commons.resource.SetOfAcrs;
import org.eclipse.om2m.interworking.service.InterworkingService;
import org.eclipse.om2m.sui.config.SuiConfig;
import org.eclipse.om2m.sui.ptb.PtbBuilder;
import org.eclipse.om2m.sui.ptb.PtbBuilder.AccessResult;
import org.eclipse.om2m.sui.sdk.NativePtbBuilder;
import org.eclipse.om2m.sui.trust.TrustScoringEngine;
import org.eclipse.om2m.sui.trust.BehaviourObserver;
import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

/**
 * Blockchain-backed Dynamic Authorization Server, conformant to the
 * oneM2M TS-0003 dynamic authorization interface.
 *
 * <p>Registered with the CSE as an {@link InterworkingService}. When the
 * CSE encounters a resource governed by a DynamicAuthorizationConsultation,
 * it issues a NOTIFY carrying a {@link SecurityInfo} of type
 * DYNAMIC_AUTHORIZATION_REQUEST to this DAS's point of access. This DAS
 * resolves the decision by executing the atomic 6-step access-control PTB
 * on Sui and returns a standard {@link DynAuthDasResponse} with granted
 * privileges (on PTB success) or ACCESS_DENIED (on PTB abort).
 *
 * <p>No modification of OM2M core is required: this plugs into the CSE
 * through oneM2M's own dynamic-authorization extension point. The OSGi
 * registration used here ({@code registerService(InterworkingService.class,
 * ..)}) is exactly the registration OM2M's own DAS conformance suite uses
 * (org.eclipse.om2m.das.testsuite.ae.AbstractDASServiceTest).
 *
 * <p><b>Verified enforcement contract</b> (org.eclipse.om2m.core, bundle
 * version 1.1.0 -- the version shipped by OM2M releases 1.3.0 through 1.5.0):
 *
 * <ul>
 * <li>{@code Controller.checkPermissions} consults DACs <em>only after the
 *     static ACP check has already failed</em>. Dynamic authorization can
 *     therefore only ever ADD access, never revoke a static grant. Making this
 *     DAS authoritative requires the protecting ACP to grant the originator
 *     nothing.</li>
 * <li>Only resource types whose controller calls {@code checkPermissions} are
 *     DAC-enforced: AE, AEAnnc, FlexContainer, FlexContainerAnnc, MgmtObj,
 *     MgmtObjAnnc, Node and Discovery. {@code ContainerController},
 *     {@code ContentInstanceController}, {@code GroupController} and
 *     {@code SubscriptionController} call the plain {@code checkACP} and are
 *     NEVER consulted dynamically -- a {@code <container>} cannot be protected
 *     by a DAS on this stack.</li>
 * <li>{@code DynamicAuthorizationSelector.checkACPs} compares the granted
 *     {@code accessControlOperations} to the requested operation with
 *     {@code equals()}, not a bitwise AND. The granted privilege must echo the
 *     requested operation exactly; a permissive {@code acop=63} would be
 *     REJECTED. See the grant built in step 6 below.</li>
 * </ul>
 */
public final class SuiDasService implements InterworkingService {

    private static final Log LOG = LogFactory.getLog(SuiDasService.class);

    private final SuiConfig cfg;
    private final PtbBuilder ptb;
    private volatile NativePtbBuilder nativePtb;
    private final String apocPath;

    // Decision cache (opt-in via sui.das.cache.ttl.ms; 0 = off). Caches GRANTs only,
    // never DENYs (fail-closed). Key = originator|resource|op, value = expiry epoch ms.
    private final java.util.concurrent.ConcurrentHashMap<String,Long> grantCache =
            new java.util.concurrent.ConcurrentHashMap<>();

    private NativePtbBuilder ensureNative() throws java.io.IOException {
        NativePtbBuilder n = nativePtb;
        if (n == null) {
            synchronized (this) {
                n = nativePtb;
                if (n == null) {
                    NativePtbBuilder.Config nc = new NativePtbBuilder.Config(
                            cfg.rpcUrl,
                            cfg.packageId, cfg.packageOriginalId,
                            cfg.identityRegistryId,
                            cfg.trustRegistryId,
                            cfg.policyRegistryId,
                            cfg.auditTrailId,
                            cfg.suiClockId,
                            cfg.gasBudget,
                            cfg.minTrust);
                    n = new NativePtbBuilder(nc, java.nio.file.Paths.get(cfg.keystorePath));
                    nativePtb = n;
                }
            }
        }
        return n;
    }

    public SuiDasService(SuiConfig cfg, PtbBuilder ptb) {
        this.cfg = cfg;
        this.ptb = ptb;
        // Application point-of-contact path the CSE dispatches NOTIFYs to.
        this.apocPath = cfg.dasApocPath; // e.g. "sui-das"
    }

    @Override
    public String getAPOCPath() {
        return apocPath;
    }

    @Override
    public ResponsePrimitive doExecute(RequestPrimitive request) {
        ResponsePrimitive response = new ResponsePrimitive(request);

        // 1. The dynamic authorization protocol uses NOTIFY exclusively.
        if (!Operation.NOTIFY.equals(request.getOperation())) {
            response.setResponseStatusCode(ResponseStatusCode.OPERATION_NOT_ALLOWED);
            return response;
        }

        // 2. Extract and validate the SecurityInfo envelope.
        //
        // Production path: OM2M's DynamicAuthorizationSelector / Redirector
        // delivers a typed SecurityInfo object via in-JVM call.
        // Test/external path: an HTTP NOTIFY arrives with a JSON string
        // body, which we deserialize here to exercise the same downstream
        // code in environments where the in-JVM trigger is unavailable.
        SecurityInfo securityInfo = null;
        Object content = request.getContent();
        if (content instanceof SecurityInfo) {
            securityInfo = (SecurityInfo) content;
        } else if (content instanceof String) {
            try {
                com.fasterxml.jackson.databind.ObjectMapper om =
                    new com.fasterxml.jackson.databind.ObjectMapper();
                com.fasterxml.jackson.databind.JsonNode root = om.readTree((String) content);
                com.fasterxml.jackson.databind.JsonNode sec = root.has("m2m:sec")
                    ? root.get("m2m:sec") : root;
                com.fasterxml.jackson.databind.JsonNode dreq = sec.path("dreq");
                if (dreq.isMissingNode()) {
                    fireMalformedTrustHook(request);
                    response.setResponseStatusCode(ResponseStatusCode.CONTENTS_UNACCEPTABLE);
                    return response;
                }
                securityInfo = new SecurityInfo();
                securityInfo.setSecurityInfoType(
                    sec.has("sit") ? java.math.BigInteger.valueOf(sec.get("sit").asLong())
                                   : SecurityInfoType.DYNAMIC_AUTHORIZATION_REQUEST);
                DynAuthDasRequest dr = new DynAuthDasRequest();
                if (dreq.hasNonNull("or"))  dr.setOriginator(dreq.get("or").asText());
                if (dreq.hasNonNull("op"))  dr.setOperation(java.math.BigInteger.valueOf(dreq.get("op").asLong()));
                if (dreq.hasNonNull("rid")) dr.setTargetedResourceID(dreq.get("rid").asText());
                if (dreq.hasNonNull("rty")) dr.setTargetedResourceType(java.math.BigInteger.valueOf(dreq.get("rty").asLong()));
                securityInfo.setDasRequest(dr);
            } catch (Exception e) {
                LOG.warn("Failed to parse SecurityInfo JSON: " + e.getMessage());
                fireMalformedTrustHook(request);
                response.setResponseStatusCode(ResponseStatusCode.CONTENTS_UNACCEPTABLE);
                return response;
            }
        } else {
            response.setResponseStatusCode(ResponseStatusCode.CONTENTS_UNACCEPTABLE);
            return response;
        }
        if (securityInfo == null
                || !SecurityInfoType.DYNAMIC_AUTHORIZATION_REQUEST
                        .equals(securityInfo.getSecurityInfoType())) {
            response.setResponseStatusCode(ResponseStatusCode.CONTENTS_UNACCEPTABLE);
            return response;
        }

        DynAuthDasRequest dasRequest = securityInfo.getDasRequest();
        if (dasRequest == null) {
            response.setResponseStatusCode(ResponseStatusCode.ACCESS_DENIED);
            return response;
        }

        // 3. Pull the decision inputs from the standard request.
        String originator = dasRequest.getOriginator();
        BigInteger operation = dasRequest.getOperation();
        String resourceId = dasRequest.getTargetedResourceID();

        // 3b. Record which of the two inbound routes this decision came from.
        //
        // This is the one log line that distinguishes the claim under test:
        //
        //   "Sui DAC consult"    - the CSE itself asked us, in-JVM, because a
        //                          <dynamicAuthorizationConsultation> named this
        //                          DAS after a static ACP check failed. Content
        //                          arrives as a typed SecurityInfo because
        //                          DynamicAuthorizationSelector sets
        //                          MimeMediaType.OBJ and Redirector hands the
        //                          object straight to IpeSelector.
        //   "Sui NOTIFY consult" - an external HTTP NOTIFY with a JSON body,
        //                          i.e. the synthetic route used by proofs/*.sh
        //                          and bench/*. Proves the decision engine, not
        //                          the CSE's enforcement wiring.
        //
        // Note on resource identifiers: on the DAC route, targetedResourceID is
        // resourceEntity.getResourceID() - the NON-hierarchical id - whereas the
        // NOTIFY route hand-writes a hierarchical uri. The two only agree if the
        // on-chain policy is keyed by the non-hierarchical id. That id is stable
        // across reboots only when the resource was created by an originator
        // beginning with "C": AEController then sets
        // aeid = request.getFrom() and resourceID = "/" + CSE_ID + "/" + aeid,
        // instead of generating a fresh random id. bench/provision_das.sh
        // relies on exactly that, so /in-cse/Csui-dac-ae survives a reboot and
        // can be provisioned on-chain once. Do NOT create the DAC-protected
        // resource as admin:admin or its id - and therefore its on-chain policy
        // key - will change on every CSE restart.
        final boolean viaDac = (content instanceof SecurityInfo);
        LOG.info((viaDac ? "Sui DAC consult" : "Sui NOTIFY consult")
                 + ": originator=" + originator
                 + " resource=" + resourceId
                 + " op=" + operation);

        // 4. Resolve Sui-side identifiers. The originator -> Sui address and
        //    (originator,resource) -> CapToken mappings are provisioned by the
        //    IN-CSE when tokens are minted (see SuiConfig / token index).
        String requesterAddress = cfg.resolveAddress(originator);
        String tokenObjectId = cfg.resolveToken(originator, resourceId);
        if (requesterAddress == null || tokenObjectId == null) {
            LOG.warn("No Sui mapping for originator=" + originator + " resource=" + resourceId);
            response.setResponseStatusCode(ResponseStatusCode.ACCESS_DENIED);
            return response;
        }

        byte op = mapOperation(operation);

        // 4b. Decision-cache check (opt-in). A recent GRANT is reusable within the
        //      TTL window; the chain call is skipped entirely on a hit. DENYs are
        //      never cached, so a stale entry can never turn a denial into a grant.
        final String cacheKey = originator + "|" + resourceId + "|" + op;
        boolean cacheHit = false;
        if (cfg.cacheTtlMs > 0) {
            Long expiry = grantCache.get(cacheKey);
            if (expiry != null && System.currentTimeMillis() < expiry) {
                cacheHit = true;
            } else if (expiry != null) {
                grantCache.remove(cacheKey); // expired; evict
            }
        }

        // 5. Execute the atomic 6-step PTB on Sui (skipped on a cache hit).
        AccessResult result;
        if (cacheHit) {
            result = AccessResult.granted(0L, "cached");
        } else if (cfg.useNativeRpc) {
            try {
                NativePtbBuilder.Result nr = ensureNative().evaluate(
                        requesterAddress, tokenObjectId, resourceId, op);
                result = nr.granted
                        ? AccessResult.granted(nr.elapsedMs, nr.digest)
                        : AccessResult.denied(nr.elapsedMs, nr.error == null ? "denied" : nr.error);
            } catch (Exception e) {
                result = AccessResult.denied(0L, "native: " + e.getMessage());
            }
        } else {
            result = ptb.evaluate(
                    requesterAddress,
                    tokenObjectId,
                    resourceId,
                    op,
                    cfg.minTrust);
        }

        if (!result.granted) {
            LOG.info("Sui DENY originator=" + originator + " resource=" + resourceId + " op=" + op + " err=" + AbortDecoder.decode(result.digestOrError) + " [raw: " + result.digestOrError + "]");
        // Trust observer hook: record this access decision against the requester.
        try {
            BehaviourObserver obs = TrustScoringEngine.activeObserver();
            if (obs != null && requesterAddress != null) {
                long _now = System.currentTimeMillis();
                obs.recordRequest(requesterAddress, resourceId, result.granted, false, _now);
            }
        } catch (Throwable _t) { /* never let trust break access path */ }

            response.setResponseStatusCode(ResponseStatusCode.ACCESS_DENIED);
            return response;
        }

        if (cfg.cacheTtlMs > 0 && !cacheHit) {
            grantCache.put(cacheKey, System.currentTimeMillis() + cfg.cacheTtlMs);
        }
        if (cacheHit) {
            LOG.info("Sui GRANT (cached) originator=" + originator + " resource=" + resourceId
                     + " op=" + op);
        } else {
            LOG.info("Sui GRANT originator=" + originator + " resource=" + resourceId
                     + " op=" + op + " digest=" + result.digestOrError + " (" + result.elapsedMs + " ms)");
        }
        // Trust observer hook: record this access decision against the requester.
        try {
            BehaviourObserver obs = TrustScoringEngine.activeObserver();
            if (obs != null && requesterAddress != null) {
                long _now = System.currentTimeMillis();
                obs.recordRequest(requesterAddress, resourceId, result.granted, false, _now);
            }
        } catch (Throwable _t) { /* never let trust break access path */ }


        // 6. Build a standard DynAuthDasResponse granting exactly the
        //    requested operation to the requesting originator.
        SecurityInfo responseSecurityInfo = new SecurityInfo();
        responseSecurityInfo.setSecurityInfoType(SecurityInfoType.DYNAMIC_AUTHORIZATION_RESPONSE);
        responseSecurityInfo.setDasResponse(new DynAuthDasResponse());
        responseSecurityInfo.getDasResponse().setDynamicACPInfo(new DynamicACPInfo());
        responseSecurityInfo.getDasResponse().getDynamicACPInfo()
                .setGrantedPrivileges(new SetOfAcrs());

        AccessControlRule acr = new AccessControlRule();
        acr.setAccessControlOperations(operation);
        acr.getAccessControlOriginators().add(originator);
        responseSecurityInfo.getDasResponse().getDynamicACPInfo()
                .getGrantedPrivileges().getAccessControlRule().add(acr);

        // If the request arrived via HTTP (content was a String), the OM2M
        // Jetty servlet expects a String back; serialize SecurityInfo to JSON.
        // If it arrived via the in-JVM Redirector path, content was already
        // an object — return the object as-is.
        if (content instanceof String) {
            try {
                com.fasterxml.jackson.databind.ObjectMapper om =
                    new com.fasterxml.jackson.databind.ObjectMapper();
                com.fasterxml.jackson.databind.node.ObjectNode root = om.createObjectNode();
                com.fasterxml.jackson.databind.node.ObjectNode sec = root.putObject("m2m:sec");
                sec.put("sit", 2); // DYNAMIC_AUTHORIZATION_RESPONSE
                com.fasterxml.jackson.databind.node.ObjectNode dresp = sec.putObject("dresp");
                com.fasterxml.jackson.databind.node.ObjectNode dacp = dresp.putObject("dacp");
                com.fasterxml.jackson.databind.node.ObjectNode pv = dacp.putObject("pv");
                com.fasterxml.jackson.databind.node.ArrayNode acrs = pv.putArray("acr");
                com.fasterxml.jackson.databind.node.ObjectNode acrJson = acrs.addObject();
                acrJson.put("acop", operation.longValue());
                com.fasterxml.jackson.databind.node.ArrayNode acors = acrJson.putArray("acor");
                acors.add(originator);
                response.setContent(om.writeValueAsString(root));
            } catch (Exception e) {
                LOG.warn("Failed to serialize DynAuthDasResponse JSON: " + e.getMessage());
                response.setContent(responseSecurityInfo); // best effort
            }
        } else {
            response.setContent(responseSecurityInfo);
        }
        response.setResponseStatusCode(ResponseStatusCode.OK);
        return response;
    }

    /** Map oneM2M operation BigInteger constants to the cap_token op bitmask. */
    private static byte mapOperation(BigInteger operation) {
        if (operation == null) return 1;
        if (operation.equals(Operation.RETRIEVE))  return 1; // OP_READ
        if (operation.equals(Operation.CREATE))    return 2; // OP_WRITE
        if (operation.equals(Operation.UPDATE))    return 2; // OP_WRITE
        if (operation.equals(Operation.DELETE))    return 4; // OP_DELETE
        if (operation.equals(Operation.NOTIFY))    return 1;
        if (operation.equals(Operation.DISCOVERY)) return 1;
        return 1;
    }

    /** Fire malformed-payload signal against whoever sent this raw request. */
    private void fireMalformedTrustHook(RequestPrimitive request) {
        try {
            org.eclipse.om2m.sui.trust.BehaviourObserver obs =
                org.eclipse.om2m.sui.trust.TrustScoringEngine.activeObserver();
            if (obs == null) return;
            String httpOrig = request.getFrom();
            if (httpOrig == null) return;
            String addr = cfg.resolveAddress(httpOrig);
            if (addr == null) return;
            long now = System.currentTimeMillis();
            obs.recordRequest(addr, null, /*granted=*/false, /*malformed=*/true, now);
        } catch (Throwable _t) { /* trust must never break access */ }
    }

}
