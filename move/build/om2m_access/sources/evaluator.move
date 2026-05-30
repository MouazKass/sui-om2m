// evaluator.move
//
// PTB step 5 of slide 9 ("Decision") plus the orchestrator that ties
// steps 1-6 together inside a single atomic transaction.
//
// What the Java proxy actually does (slide 9):
//
//   sui client ptb \
//     --move-call PKG::identity::verify    <registry> <requester>   \
//     --move-call PKG::trust::require_min  <trust_reg> <requester> <min> <clock> -> $trust  \
//     --move-call PKG::cap_token::validate_for_use <token> <res_id> <op> <clock>  \
//     --move-call PKG::policy::evaluate    <pol_reg> <res_id> <op> $trust <clock> -> $min  \
//     --move-call PKG::evaluator::decide_and_log <trail> <requester> <res_id> <op> $trust <token_uses> <clock>
//
// Steps 1-4 are direct module calls; this module wraps step 5 (Decision)
// and step 6 (Audit) into one call so the PTB has a single closing
// command that takes everything previous as arguments.
//
// Note: there is NO separate "decision" boolean to evaluate here. If any
// of steps 1-4 had failed they would have aborted and rolled back the
// PTB. Reaching this function at all is the decision = GRANTED. The
// only role of `decide_and_log` is to record that fact atomically.
//
// For denied requests the proxy still wants an on-chain record. That
// path uses `log_denied` from outside the access PTB — see comment in
// the Java DenialRecorder for why this isn't in the hot path.

module om2m_access::evaluator {
    use std::string::String;
    use sui::tx_context::{Self, TxContext};
    use sui::clock::Clock;

    use om2m_access::audit::{Self, AuditTrail};
    use om2m_access::cap_token::CapToken;

    // === PTB step 5 + 6: Decision (implicit) and Audit ===
    public fun decide_and_log(
        trail: &mut AuditTrail,
        requester: address,
        resource_id: String,
        requested_op: u8,
        trust_at_check: u64,
        token: &CapToken,
        clock: &Clock,
        _ctx: &TxContext,
    ) {
        // Reaching this function means steps 1-4 all passed. Decision is
        // GRANTED by construction of the PTB.
        let token_uses = om2m_access::cap_token::current_uses(token);

        audit::log(
            trail,
            requester,
            resource_id,
            requested_op,
            audit::decision_granted(),
            trust_at_check,
            token_uses,
            clock,
        );
    }

    // === Out-of-band denial recorder ===
    // For requests that fail step 1-4 the PTB aborts and rolls back the
    // audit log — which means denials don't appear on-chain. That is
    // *correct* for atomicity but bad for forensics, so the proxy
    // submits a separate, single-tx call to this function with whatever
    // info it has.
    public fun log_denied(
        trail: &mut AuditTrail,
        requester: address,
        resource_id: String,
        requested_op: u8,
        trust_at_check: u64,
        clock: &Clock,
    ) {
        audit::log(
            trail,
            requester,
            resource_id,
            requested_op,
            audit::decision_denied(),
            trust_at_check,
            0, // no token consumed
            clock,
        );
    }
}
