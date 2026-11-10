// evaluator.move
//
// PTB step 5 of slide 9 ("Decision") plus the orchestrator that ties
// steps 1-6 together inside a single atomic transaction.
//
// A6: the five steps are no longer independent calls glued together by
// plain u64/address values that a hand-rolled PTB could forge or skip.
// Each step now returns a "hot potato" receipt — a struct with NO drop,
// store, copy or key — that the next step consumes BY VALUE. The chain is
// therefore enforced by the Move type system, not by convention.
//
// What the Java proxy must now build (note: the signer IS the requester;
// there is no requester argument anywhere in the chain):
//
//   sui client ptb \
//     --move-call PKG::identity::verify <id_reg>                        \
//       --assign r1                                                     \
//     --move-call PKG::trust::require_min r1 <trust_reg> <res_id> <min> <clock> \
//       --assign r2                                                     \
//     --move-call PKG::cap_token::validate_for_use r2 <token> <op> <clock> \
//       --assign r3                                                     \
//     --move-call PKG::policy::evaluate r3 <pol_reg> <trust_reg> <clock> \
//       --assign r4                                                     \
//     --move-call PKG::evaluator::decide_and_log r4 <trail> <clock>
//
// (&TxContext parameters are supplied implicitly by the runtime and are
// not passed on the command line.)
//
// Because the receipts cannot be dropped or stored, a PTB that calls
// verify and then stops, or that tries to jump straight to
// decide_and_log, cannot be executed at all.
//
// Note: there is NO separate "decision" boolean to evaluate here. If any
// of steps 1-4 had failed they would have aborted and rolled back the
// PTB. Holding a PolicyReceipt IS the decision = GRANTED. The only role
// of `decide_and_log` is to record that fact atomically.
//
// For denied requests the proxy still wants an on-chain record. That path
// uses `log_denied_authorized` (AuditAdminCap-gated) from outside the
// access PTB — see comment in the Java DenialRecorder for why this isn't
// in the hot path.

module om2m_access::evaluator {
    use std::string::String;
    use sui::clock::Clock;

    use om2m_access::audit::{Self, AuditTrail, AuditAdminCap};
    use om2m_access::policy::{Self, PolicyReceipt};
    use om2m_access::identity::{Self, IdentityReceipt, Registry as IdentityRegistry};
    use om2m_access::trust::{Self, TrustRegistry, AdminCap as TrustAdminCap};

    // v9 (F3) errors for log_deny_batch. They start at 100 so they cannot be
    // confused with the abort codes of the modules this one calls.
    const E_NOT_MIDDLEWARE: u64 = 100;
    const E_NODE_CAP_INVALID: u64 = 101;

    // === PTB step 5 + 6: Decision (implicit) and Audit ===
    //
    // A6/A7: every field of the audit record now comes out of the
    // PolicyReceipt, which can only exist if identity -> trust -> token ->
    // policy all ran, in order, in this transaction, for this requester.
    // There are no caller-supplied requester / resource / trust arguments
    // left to forge, so this function cannot be used to mint a fake GRANT
    // record even though it is reachable from a PTB.
    //
    // It must stay `public` (not `public(package)`): it is the closing
    // command of the access PTB, so external callability is required. The
    // authorization is the receipt, not the visibility — see the WS1 report.
    public fun decide_and_log(
        policy_receipt: PolicyReceipt,
        trail: &mut AuditTrail,
        clock: &Clock,
    ) {
        // Reaching this function means steps 1-4 all passed. Decision is
        // GRANTED by construction of the chain.
        let (requester, resource_id, requested_op, trust_score, _min_trust, token_uses) =
            policy::consume_policy_receipt(policy_receipt);

        audit::log(
            trail,
            requester,
            resource_id,
            requested_op,
            audit::decision_granted(),
            trust_score,
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
    //
    // A7: this used to be `public fun` with no authorization at all, i.e. any
    // address could write arbitrary DENY records (wrong requester, wrong
    // resource, wrong trust score) into the canonical audit trail and poison
    // the forensic record. It is now `public(package)`, reachable only from
    // inside om2m_access — external callers must use
    // `log_denied_authorized`, which requires the AuditAdminCap.
    public(package) fun log_denied(
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

    /// Authorized external denial recorder (A7).
    ///
    /// The proxy's out-of-band denial path still needs to reach the audit
    /// trail from its own single-call transaction, which `public(package)`
    /// alone would make impossible. This wrapper restores that path but gates
    /// it on the AuditAdminCap minted to the publisher in audit::init — so
    /// the IN-CSE can record denials and nobody else can.
    public fun log_denied_authorized(
        _admin: &AuditAdminCap,
        trail: &mut AuditTrail,
        requester: address,
        resource_id: String,
        requested_op: u8,
        trust_at_check: u64,
        clock: &Clock,
    ) {
        log_denied(trail, requester, resource_id, requested_op, trust_at_check, clock);
    }

    // v9 (F3): anchor one window of this node's local DENY log on-chain.
    //
    // The PTB is `identity::verify(id_reg)` then this function with the
    // receipt, so the node address is the transaction signer (A3) and is
    // never a caller-supplied argument. Gated three ways:
    //   * the signer is a registered IN-CSE or MN-CSE (not an AE);
    //   * the signer passes a trust AdminCap that is currently valid in the
    //     TrustRegistry (an owned object, so only its owner can pass it;
    //     governed-aware via trust::is_cap_valid);
    //   * audit::log_deny_batch limits each node to one batch per
    //     DENY_BATCH_MIN_INTERVAL_MS and rejects overlapping windows.
    public fun log_deny_batch(
        identity_receipt: IdentityReceipt,
        id_reg: &IdentityRegistry,
        node_cap: &TrustAdminCap,
        trust_reg: &TrustRegistry,
        trail: &mut AuditTrail,
        window_start_ms: u64,
        window_end_ms: u64,
        deny_count: u64,
        distinct_keys: u64,
        digest: vector<u8>,
        clock: &Clock,
    ) {
        let node = identity::consume_identity_receipt(identity_receipt);
        let role = identity::role_of(id_reg, node);
        assert!(role == identity::role_in_cse() || role == identity::role_mn_cse(), E_NOT_MIDDLEWARE);
        assert!(trust::is_cap_valid(trust_reg, sui::object::id(node_cap)), E_NODE_CAP_INVALID);
        audit::log_deny_batch(trail, node, window_start_ms, window_end_ms,
                              deny_count, distinct_keys, digest, clock);
    }
}
