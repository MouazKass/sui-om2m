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
 * through oneM2M's own dynamic-authorization extension point.
 */
public final class SuiDasService implements InterworkingService {

    private static final Log LOG = LogFactory.getLog(SuiDasService.class);

    private final SuiConfig cfg;
    private final PtbBuilder ptb;
    private volatile NativePtbBuilder nativePtb;
    private final String apocPath;

    private NativePtbBuilder ensureNative() throws java.io.IOException {
        NativePtbBuilder n = nativePtb;
        if (n == null) {
            synchronized (this) {
                n = nativePtb;
                if (n == null) {
                    NativePtbBuilder.Config nc = new NativePtbBuilder.Config(
                            cfg.rpcUrl,
                            cfg.packageId,
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

        // 5. Execute the atomic 6-step PTB on Sui.
        AccessResult result;
        if (cfg.useNativeRpc) {
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
            LOG.info("Sui DENY originator=" + originator + " resource=" + resourceId + " op=" + op + " err=" + result.digestOrError);
            response.setResponseStatusCode(ResponseStatusCode.ACCESS_DENIED);
            return response;
        }

        LOG.info("Sui GRANT originator=" + originator + " resource=" + resourceId + " op=" + op + " digest=" + result.digestOrError + " (" + result.elapsedMs + " ms)");

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
}
