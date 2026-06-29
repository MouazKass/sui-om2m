/// This module simulates an adversary-published module that tries to call the
/// unguarded trust::increase directly, bypassing the self-scoring guard in
/// increase_guarded. If trust::increase is public(package), THIS WILL NOT COMPILE.
/// If it were public (as in v6), it would compile. The compile result is the proof.
module selfscore_attack::attack {
    use om2m_access::trust::{Self, AdminCap, TrustRegistry};
    use sui::clock::Clock;

    /// Attempt to raise `victim`'s score by calling the UNGUARDED primitive,
    /// skipping the sender != node assertion that increase_guarded enforces.
    public fun try_self_score(
        admin: &AdminCap,
        registry: &mut TrustRegistry,
        victim: address,
        amount: u64,
        clock: &Clock,
    ) {
        // Direct call to the unguarded primitive. This is the bypass attempt.
        trust::increase(admin, registry, victim, amount, clock);
    }
}
