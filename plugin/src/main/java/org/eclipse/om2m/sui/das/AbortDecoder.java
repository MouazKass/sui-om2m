package org.eclipse.om2m.sui.das;

import java.util.HashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Decodes a native MoveAbort error string into a readable
 * "module::E_NAME (abort N)" label. Defensive: non-MoveAbort errors (e.g. RPC
 * errors) are returned unchanged. Constant tables mirror move/sources/*.move.
 */
final class AbortDecoder {

    private AbortDecoder() {}

    private static final Map<String, String> NAMES = new HashMap<>();
    static {
        NAMES.put("identity:1", "E_NOT_REGISTERED");
        NAMES.put("identity:2", "E_ALREADY_REGISTERED");
        NAMES.put("trust:1", "E_NOT_FOUND");
        NAMES.put("trust:2", "E_TRUST_TOO_LOW");
        NAMES.put("trust:3", "E_ALREADY_EXISTS");
        NAMES.put("trust:4", "E_SELF_SCORING");
        NAMES.put("trust:5", "E_CAP_REVOKED");
        NAMES.put("cap_token:1", "E_TOKEN_EXPIRED");
        NAMES.put("cap_token:2", "E_TOKEN_EXHAUSTED");
        NAMES.put("cap_token:3", "E_RESOURCE_MISMATCH");
        NAMES.put("cap_token:4", "E_OP_NOT_ALLOWED");
        NAMES.put("policy:1", "E_POLICY_MISSING");
        NAMES.put("policy:2", "E_OP_DENIED");
        NAMES.put("policy:3", "E_TRUST_BELOW_MIN");
        NAMES.put("policy:4", "E_IN_BLACKOUT");
        NAMES.put("policy:5", "E_BAD_WINDOW");
        NAMES.put("evolution:2", "E_NO_TIER_FIELD");
        NAMES.put("audit:1", "E_BAD_RING_SIZE");
    }

    private static final Pattern MODULE =
        Pattern.compile("name:\\s*Identifier\\(\"(\\w+)\"\\)");
    private static final Pattern CODE =
        Pattern.compile("\\},\\s*(\\d+)\\)");

    static String decode(String rawError) {
        if (rawError == null || rawError.isEmpty()) return "denied";
        Matcher mod = MODULE.matcher(rawError);
        Matcher code = CODE.matcher(rawError);
        if (mod.find() && code.find()) {
            String module = mod.group(1);
            String c = code.group(1);
            String name = NAMES.get(module + ":" + c);
            if (name != null) {
                return module + "::" + name + " (abort " + c + ")";
            }
            return module + "::abort " + c;
        }
        return rawError;
    }
}
