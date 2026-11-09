package org.eclipse.om2m.sui.trust;

/**
 * B10 — the set of middleware nodes that are actually registered in the cluster.
 *
 * <p>Gossip authentication (see {@code GossipSig}) only proves that the sender
 * holds the private key for the address it claims. That is <i>self-certifying</i>:
 * anyone can mint a fresh Ed25519 keypair, derive its Sui address, sign a
 * perfectly valid observation with it and be admitted as a brand-new "alive
 * observer". With no membership check an attacker can therefore manufacture an
 * unbounded number of valid observers, which (a) stuffs the peer-agreement
 * denominator {@code n}, defeating the Byzantine bound in
 * {@code TrustScoringEngine.aggregateAndScore}, and (b) lets them win the
 * lexicographically-lowest-address submitter election at will.
 *
 * <p>This abstraction is the authorisation half that was missing: an observer is
 * admitted only if it appears in the on-chain {@code om2m_access::identity}
 * registry, which is written exclusively with the IN-CSE's {@code AdminCap}.
 *
 * @see IdentityRegistryMembers the on-chain implementation
 */
interface MemberRegistry {

    /**
     * @return true iff {@code addr} is a registered cluster member and may
     *         therefore act as a trust observer. Implementations must
     *         fail <b>closed</b>: when membership cannot be established, the
     *         answer is {@code false}.
     */
    boolean isMember(String addr);
}
