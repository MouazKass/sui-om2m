package org.eclipse.om2m.sui.trust;

/**
 * One observer's view of one target node over the current rolling window.
 *
 * <p>Each field in groups 1 and 2 is a <b>health value in [0,1]</b> already
 * normalised by {@link BehaviourObserver} (1.0 = perfect behaviour, 0.0 =
 * worst). Group 3 fields are raw boolean <b>flags</b> — whether <i>this single
 * observer</i> believes the target committed that violation. The peer-agreement
 * rule (≥ threshold observers must agree) is applied later by the engine when it
 * aggregates observations from all nodes, so a lone observer can never by itself
 * zero out a target's attestation score.
 *
 * <p>Instances are produced once per tick, published over MQTT as a compact
 * pipe-delimited string, and consumed by every node's engine. Keeping the wire
 * format trivial avoids pulling a JSON dependency into the OSGi bundle.
 */
final class NodeObservation {

    final String observerAddr;   // who saw this
    String sigB64;               // ed25519 signature over the unsigned wire string (nullable)
    String pubKeyB64;            // flag-prefixed signer public key (nullable)
    final String targetAddr;     // who it is about
    final long   producedAtMs;

    // Group 1 — protocol-level health [0,1]
    final double heartbeatHealth;
    final double malformedHealth;
    final double rateHealth;
    final double clockHealth;

    // Group 2 — access-pattern health [0,1]
    final double deniedBurstHealth;
    final double ptbAbortHealth;
    final double historicalHealth;
    final double inactiveHealth;

    // Group 3 — this observer's raw violation flags
    final boolean impersonationFlag;
    final boolean garbageFlag;
    final boolean mqttMismatchFlag;

    NodeObservation(
        String observerAddr, String targetAddr, long producedAtMs,
        double heartbeatHealth, double malformedHealth, double rateHealth, double clockHealth,
        double deniedBurstHealth, double ptbAbortHealth, double historicalHealth, double inactiveHealth,
        boolean impersonationFlag, boolean garbageFlag, boolean mqttMismatchFlag
    ) {
        this.observerAddr = observerAddr;
        this.targetAddr = targetAddr;
        this.producedAtMs = producedAtMs;
        this.heartbeatHealth = heartbeatHealth;
        this.malformedHealth = malformedHealth;
        this.rateHealth = rateHealth;
        this.clockHealth = clockHealth;
        this.deniedBurstHealth = deniedBurstHealth;
        this.ptbAbortHealth = ptbAbortHealth;
        this.historicalHealth = historicalHealth;
        this.inactiveHealth = inactiveHealth;
        this.impersonationFlag = impersonationFlag;
        this.garbageFlag = garbageFlag;
        this.mqttMismatchFlag = mqttMismatchFlag;
    }

    /**
     * Compact wire format:
     * {@code v1|observer|target|ts|hb|mal|rate|clk|den|abrt|hist|inact|imp|gar|mqtt}
     */
    String encode() {
        StringBuilder sb = new StringBuilder(160);
        sb.append("v1|").append(observerAddr).append('|').append(targetAddr).append('|')
          .append(producedAtMs).append('|')
          .append(f(heartbeatHealth)).append('|').append(f(malformedHealth)).append('|')
          .append(f(rateHealth)).append('|').append(f(clockHealth)).append('|')
          .append(f(deniedBurstHealth)).append('|').append(f(ptbAbortHealth)).append('|')
          .append(f(historicalHealth)).append('|').append(f(inactiveHealth)).append('|')
          .append(b(impersonationFlag)).append('|').append(b(garbageFlag)).append('|')
          .append(b(mqttMismatchFlag));
        return sb.toString();
    }

    /** The exact bytes that get signed/verified (the unsigned 15-field form). */
    byte[] unsignedBytes() {
        return encode().getBytes(java.nio.charset.StandardCharsets.UTF_8);
    }

    /** Full signed wire string: unsigned form + |sig|pubkey. */
    String encodeSigned() {
        String base = encode();
        if (sigB64 == null || pubKeyB64 == null) return base;
        return base + "|" + sigB64 + "|" + pubKeyB64;
    }

    /** Parse a wire string. Returns null if malformed or wrong version. */
    static NodeObservation decode(String s) {
        if (s == null) return null;
        String[] t = s.split("\\|");
        if ((t.length != 15 && t.length != 17) || !"v1".equals(t[0])) return null;
        try {
            NodeObservation o = new NodeObservation(
                t[1], t[2], Long.parseLong(t[3]),
                Double.parseDouble(t[4]), Double.parseDouble(t[5]),
                Double.parseDouble(t[6]), Double.parseDouble(t[7]),
                Double.parseDouble(t[8]), Double.parseDouble(t[9]),
                Double.parseDouble(t[10]), Double.parseDouble(t[11]),
                "1".equals(t[12]), "1".equals(t[13]), "1".equals(t[14]));
            if (t.length == 17) { o.sigB64 = t[15]; o.pubKeyB64 = t[16]; }
            return o;
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static String f(double v) {
        // 3 decimals is plenty for a [0,1] health value and keeps the payload tiny.
        return String.format(java.util.Locale.ROOT, "%.3f", v);
    }
    private static String b(boolean v) { return v ? "1" : "0"; }
}
