# EVO5: A Revoked Parent Token Makes Its Sub-Capabilities Unreachable — Evidence

Status: VERIFIED on the live testnet cluster, 2026-06-23.

## Invariant
evolution::attach_sub_capability transfers a SubCapability to the token object
(Transfer-to-Object). Revoking the parent deletes the token, orphaning the
child. Claimed by construction; this exercises it live.

## Test sequence (all from the publisher, holder of cap_token::IssuerCap)
1. mint -> parent CapToken 0x26f1d5d5...c7f2, resource_id=/evo5/parent-test,
   owned by publisher.
2. attach_sub_capability -> SubCapability 0x3250f4a6...2ab6,
   granted_for=/evo5/parent-test/child; event SubCapabilityAttached emitted.
3. BEFORE revoke - child REACHABLE: the SubCapability's owner is the PARENT
   TOKEN object 0x26f1d5d5...c7f2 (Transfer-to-Object; rendered as AddressOwner
   = the parent object's id). The child is parented to the token.
4. revoke(IssuerCap, parent) -> parent token 0x26f1d5d5...c7f2 appears under
   Deleted Objects (CT5: irrecoverable).
5. AFTER revoke - child UNREACHABLE:
   - The child object still exists in storage, still owned by 0x26f1d5d5...c7f2.
   - The parent (its owner) no longer exists (fetch returns nothing).
   - Attempting to USE the child (transfer it) fails: the runtime must authorize
     as the owner 0x26f1d5d5...c7f2, but that owner is a DELETED object — it has
     no keypair and cannot sign. Error:
       "Cannot find gas coin for signer address 0x26f1d5d5...c7f2 ..."
     No transaction can ever authenticate as a deleted object, so the
     sub-capability can never be exercised by anyone.

## Conclusion
Revoking a parent token permanently orphans its sub-capabilities: the child
remains in storage but is owned by a non-existent object, so no party can ever
authorize its use. The sub-capability is unreachable — EVO5 holds, demonstrated
both by construction (Transfer-to-Object semantics) and by a live failed-use
attempt.
