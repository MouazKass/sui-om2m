package org.eclipse.om2m.sui.trust;

/**
 * One observer's view of one target node over the current rolling window.
 *
 * <p>Each health field is a <b>health value in [0,1]</b> already normalised by
 * {@link BehaviourObserver} (1.0 = perfect behaviour, 0.0 = worst).
 * {@link #garbageFlag} is a raw boolean <b>flag</b> — whether <i>this single
 * observer</i> believes the target emitted out-of-range telemetry. The
 * peer-agreement rule (&ge; k observers must agree, k derived from the observer
 * count — see {@code TrustScoringEngine.aggregateAndScore}) is applied later by
 * the engine when it aggregates observations from all nodes, so a lone observer
 * can never by itself zero out a target's attestation score.
 *
 * <p>Instances are produced once per tick, published over MQTT as a compact
 * pipe-delimited string, and consumed by every node's engine. Keeping the wire
 * format trivial avoids pulling a JSON dependency into the OSGi bundle.
 *
 * <p><b>B6 — wire format v2.</b> v1 carried only {@code producedAtMs} as the
 * anti-replay ordinal, so an observer whose clock jumped backwards across a
 * restart had all of its subsequent gossip rejected as "replay" forever. v2
 * adds a per-observer {@link #epoch} that increments on every process restart
 * (see {@link ObserverEpoch}); ordering is now the lexicographic pair
 * {@code (epoch, producedAtMs)}. v2 also drops the three signals removed by
 * B11/B12 (ptbAbortHealth, impersonationFlag, mqttMismatchFlag), so v1 and v2
 * payloads are NOT interchangeable and {@link #decode} rejects v1 outright.
 */
final class NodeObservation {

    final String observerAddr;   // who saw this
    String sigB64;               // ed25519 signature over the unsigned wire string (nullable)
    String pubKeyB64;            // flag-prefixed signer public key (nullable)
    final String targetAddr;     // who it is about
    /** B6: observer restart epoch. Strictly increases across process restarts. */
    final long   epoch;
    final long   producedAtMs;

    // Group 1 — protocol-level health [0,1]
    final double heartbeatHealth;
    final double malformedHealth;
    final double rateHealth;
    final double clockHealth;

    // Group 2 — access-pattern health [0,1]
    final double deniedBurstHealth;
    final double historicalHealth;
    final double inactiveHealth;

    // Group 3 — this observer's raw violation flag
    final boolean garbageFlag;

    NodeObservation(
        String observerAddr, String targetAddr, long epoch, long producedAtMs,
        double heartbeatHealth, double malformedHealth, double rateHealth, double clockHealth,
        double deniedBurstHealth, double historicalHealth, double inactiveHealth,
        boolean garbageFlag
    ) {
        this.observerAddr = observerAddr;
        this.targetAddr = targetAddr;
        this.epoch = epoch;
        this.producedAtMs = producedAtMs;
        this.heartbeatHealth = heartbeatHealth;
        this.malformedHealth = malformedHealth;
        this.rateHealth = rateHealth;
        this.clockHealth = clockHealth;
        this.deniedBurstHealth = deniedBurstHealth;
        this.historicalHealth = historicalHealth;
        this.inactiveHealth = inactiveHealth;
        this.garbageFlag = garbageFlag;
    }

    /** Number of fields in the unsigned v2 wire form. */
    static final int WIRE_FIELDS = 13;
    /** Number of fields in the signed v2 wire form (unsigned + sig + pubkey). */
    static final int WIRE_FIELDS_SIGNED = WIRE_FIELDS + 2;
    static final String WIRE_VERSION = "v2";

    /**
     * Compact wire format (v2), 13 pipe-separated fields:
     * {@code v2|observer|target|epoch|ts|hb|mal|rate|clk|den|hist|inact|gar}
     * plus {@code |sig|pubkey} when signed (15 fields).
     */
    String encode() {
        StringBuilder sb = new StringBuilder(160);
        sb.append(WIRE_VERSION).append('|')
          .append(observerAddr).append('|').append(targetAddr).append('|')
          .append(epoch).append('|').append(producedAtMs).append('|')
          .append(f(heartbeatHealth)).append('|').append(f(malformedHealth)).append('|')
          .append(f(rateHealth)).append('|').append(f(clockHealth)).append('|')
          .append(f(deniedBurstHealth)).append('|')
          .append(f(historicalHealth)).append('|').append(f(inactiveHealth)).append('|')
          .append(b(garbageFlag));
        return sb.toString();
    }

    /** The exact bytes that get signed/verified (the unsigned 13-field v2 form). */
    byte[] unsignedBytes() {
        return encode().getBytes(java.nio.charset.StandardCharsets.UTF_8);
    }

    /** Full signed wire string: unsigned form + |sig|pubkey. */
    String encodeSigned() {
        String base = encode();
        if (sigB64 == null || pubKeyB64 == null) return base;
        return base + "|" + sigB64 + "|" + pubKeyB64;
    }

    /**
     * Parse a wire string. Returns null if malformed or wrong version.
     * v1 payloads are rejected: v2 reordered the fields (epoch inserted) and
     * dropped ptbAbortHealth / impersonationFlag / mqttMismatchFlag.
     */
    static NodeObservation decode(String s) {
        if (s == null) return null;
        String[] t = s.split("\\|");
        if ((t.length != WIRE_FIELDS && t.length != WIRE_FIELDS_SIGNED)
                || !WIRE_VERSION.equals(t[0])) {
            return null;
        }
        try {
            NodeObservation o = new NodeObservation(
                t[1], t[2],
                Long.parseLong(t[3]),            // epoch
                Long.parseLong(t[4]),            // producedAtMs
                Double.parseDouble(t[5]),        // heartbeat
                Double.parseDouble(t[6]),        // malformed
                Double.parseDouble(t[7]),        // rate
                Double.parseDouble(t[8]),        // clock
                Double.parseDouble(t[9]),        // deniedBurst
                Double.parseDouble(t[10]),       // historical
                Double.parseDouble(t[11]),       // inactive
                "1".equals(t[12]));              // garbage flag
            if (t.length == WIRE_FIELDS_SIGNED) { o.sigB64 = t[13]; o.pubKeyB64 = t[14]; }
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
