// cap_token.move
//
// Layer 1 / Foundation of the unified Sui-native access control framework
// (slide 8). Each MN-CSE that has been authorized to access a remote OM2M
// resource holds a `CapToken` object in its Sui address.
//
// Properties enforced by the Move compiler (not by runtime code):
//   * `key + store` only — no `copy`, no `drop`. The bits cannot be cloned
//     and the value cannot be silently discarded. Any code that would leak
//     a token fails to compile.
//   * Single-owner moves. The Sui object model means only the address that
//     owns the token can pass it as input to a transaction.
//
// This module exposes the token resource plus mint/revoke/validate helpers.
// The atomic 6-step access flow (slide 9, step 3) calls `validate_for_use`
// inside the PTB the proxy builds.

module om2m_access::cap_token {
    use std::string::String;
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::clock::{Self, Clock};
    use sui::event;

    // === Errors ===
    const E_TOKEN_EXPIRED: u64 = 1;
    const E_TOKEN_EXHAUSTED: u64 = 2;
    const E_RESOURCE_MISMATCH: u64 = 3;
    const E_OP_NOT_ALLOWED: u64 = 4;

    // === Op codes (bitmask) ===
    // Same scheme is reused by token_evolution to widen permissions over time.
    const OP_READ:   u8 = 1; // 0b0001
    const OP_WRITE:  u8 = 2; // 0b0010
    const OP_DELETE: u8 = 4; // 0b0100
    const OP_ADMIN:  u8 = 8; // 0b1000

    // === Capabilities ===
    // Issuer capability — held by the IN-CSE's Sui address. Created once at
    // package publish time in `init`. Required for `mint`.
    public struct IssuerCap has key, store {
        id: UID,
    }

    // === Token ===
    // CapToken is intentionally `key + store` only.
    //   - No `copy`: the type system forbids duplication.
    //   - No `drop`: the value must be explicitly consumed (revoke) or
    //                transferred. A leak is a compile error.
    public struct CapToken has key, store {
        id: UID,
        // Sui address of the IN-CSE that minted this token.
        issuer: address,
        // The OM2M resource URI this token authorises (e.g.
        // "/cse-mn-1/AE-1/cnt-temp"). Kept as String so we can pass the
        // full oneM2M-style path without parsing on-chain.
        resource_id: String,
        // Bitmask of allowed ops. Checked in validate_for_use.
        allowed_ops: u8,
        // Unix-ms absolute expiry. Compared against sui::clock::Clock.
        expiry_ms: u64,
        // Hard upper bound on use count. Past this the token is rejected.
        max_uses: u64,
        // Monotonically increasing on every successful validation.
        current_uses: u64,
    }

    // === Events ===
    public struct TokenMinted has copy, drop {
        token_id: address,
        issuer: address,
        owner: address,
        resource_id: String,
        allowed_ops: u8,
        expiry_ms: u64,
        max_uses: u64,
    }

    public struct TokenRevoked has copy, drop {
        token_id: address,
        revoker: address,
    }

    public struct TokenUsed has copy, drop {
        token_id: address,
        new_use_count: u64,
    }

    // === Init ===
    // Runs once when the package is published. Mints the singleton
    // IssuerCap and transfers it to the publisher (which on our testbed is
    // the IN-CSE's Sui address).
    fun init(ctx: &mut TxContext) {
        let cap = IssuerCap { id: object::new(ctx) };
        transfer::public_transfer(cap, tx_context::sender(ctx));
    }

    // === Mint ===
    // Only the holder of IssuerCap can call this. Mints a fresh CapToken
    // and transfers it to `owner` (the MN-CSE's Sui address). Because
    // CapToken has no `drop`, this function MUST end by transferring the
    // value somewhere; the compiler enforces it.
    public fun mint(
        _issuer_cap: &IssuerCap,
        owner: address,
        resource_id: String,
        allowed_ops: u8,
        expiry_ms: u64,
        max_uses: u64,
        ctx: &mut TxContext,
    ) {
        let token = CapToken {
            id: object::new(ctx),
            issuer: tx_context::sender(ctx),
            resource_id,
            allowed_ops,
            expiry_ms,
            max_uses,
            current_uses: 0,
        };
        let token_addr = object::uid_to_address(&token.id);

        event::emit(TokenMinted {
            token_id: token_addr,
            issuer: tx_context::sender(ctx),
            owner,
            resource_id: token.resource_id,
            allowed_ops,
            expiry_ms,
            max_uses,
        });

        transfer::public_transfer(token, owner);
    }

    // === Validate ===
    // The hot path. Called as step 3 of the atomic 6-step PTB on every
    // access request. Aborts on any failure, which causes the entire PTB
    // (all six Move calls — slide 9) to roll back.
    //
    // The token is taken as `&mut` because we tick `current_uses`. It is
    // returned by reference; ownership stays with the caller. The Move
    // borrow checker keeps anyone else from seeing the mutated token mid
    // PTB.
    public fun validate_for_use(
        token: &mut CapToken,
        resource_id: &String,
        requested_op: u8,
        clock: &Clock,
    ) {
        // Resource scope.
        assert!(&token.resource_id == resource_id, E_RESOURCE_MISMATCH);

        // Op allowed by bitmask.
        assert!((token.allowed_ops & requested_op) == requested_op, E_OP_NOT_ALLOWED);

        // Time bound.
        let now = clock::timestamp_ms(clock);
        assert!(now < token.expiry_ms, E_TOKEN_EXPIRED);

        // Use count bound.
        assert!(token.current_uses < token.max_uses, E_TOKEN_EXHAUSTED);

        token.current_uses = token.current_uses + 1;

        event::emit(TokenUsed {
            token_id: object::uid_to_address(&token.id),
            new_use_count: token.current_uses,
        });
    }

    // === Revoke ===
    // Consuming the token destroys it. Because there is no `drop` ability,
    // this is the ONLY way to get rid of a token short of a transfer.
    // After this call there is provably no copy of this token anywhere.
    public fun revoke(
        _issuer_cap: &IssuerCap,
        token: CapToken,
        ctx: &TxContext,
    ) {
        let CapToken {
            id,
            issuer: _,
            resource_id: _,
            allowed_ops: _,
            expiry_ms: _,
            max_uses: _,
            current_uses: _,
        } = token;

        event::emit(TokenRevoked {
            token_id: object::uid_to_address(&id),
            revoker: tx_context::sender(ctx),
        });

        object::delete(id);
    }

    // === Public accessors (used by other modules in this package) ===
    public fun issuer(token: &CapToken): address { token.issuer }
    public fun resource_id(token: &CapToken): &String { &token.resource_id }
    public fun allowed_ops(token: &CapToken): u8 { token.allowed_ops }
    public fun expiry_ms(token: &CapToken): u64 { token.expiry_ms }
    public fun max_uses(token: &CapToken): u64 { token.max_uses }
    public fun current_uses(token: &CapToken): u64 { token.current_uses }

    // === Friend-style mutator for token_evolution ===
    // The evolution module uses this to widen permissions when the trust
    // score climbs. Kept package-private (no `entry`, no `public entry`)
    // so external transactions can't grant themselves new ops.
    public(package) fun grant_ops(token: &mut CapToken, extra_ops: u8) {
        token.allowed_ops = token.allowed_ops | extra_ops;
    }

    public(package) fun revoke_ops(token: &mut CapToken, removed_ops: u8) {
        token.allowed_ops = token.allowed_ops & (255 - removed_ops);
    }

    public(package) fun token_uid_mut(token: &mut CapToken): &mut UID {
        &mut token.id
    }

    public fun token_address(token: &CapToken): address {
        object::uid_to_address(&token.id)
    }

    // === Op-code constants exposed for other modules / clients ===
    public fun op_read():   u8 { OP_READ }
    public fun op_write():  u8 { OP_WRITE }
    public fun op_delete(): u8 { OP_DELETE }
    public fun op_admin():  u8 { OP_ADMIN }
}
