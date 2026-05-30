// identity.move
//
// PTB step 1 of slide 9's atomic 6-step evaluation: "Identity".
//
// The IN-CSE maintains an on-chain registry mapping a Sui address (the
// per-node keypair that signs PTBs from each CSE) to the OM2M node it
// represents. Step 1 of every access PTB calls `verify` against this
// registry; if the requester isn't registered the whole PTB aborts.
//
// Registry is a shared object so any node in the network can read it
// during PTB execution. Writes (register / deregister) need the
// AdminCap held by the IN-CSE.

module om2m_access::identity {
    use std::string::String;
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::event;

    // === Errors ===
    const E_NOT_REGISTERED: u64 = 1;
    const E_ALREADY_REGISTERED: u64 = 2;

    // === Roles ===
    // CSE roles. Used by trust_registry decay rules and by failover
    // (only IN/MN nodes can be parents, not AEs).
    const ROLE_IN_CSE: u8 = 1;
    const ROLE_MN_CSE: u8 = 2;
    const ROLE_AE:     u8 = 3;

    // === Capabilities ===
    public struct AdminCap has key, store { id: UID }

    // === Registry entry ===
    public struct Node has store, drop {
        cse_id: String, // OM2M-style CSE-ID, e.g. "in-cse" or "mn-cse-1"
        role: u8,
        registered_at_ms: u64,
    }

    // === Registry ===
    // Shared object — any PTB can borrow it immutably during step 1.
    public struct Registry has key {
        id: UID,
        nodes: Table<address, Node>,
    }

    // === Events ===
    public struct NodeRegistered has copy, drop {
        node_addr: address,
        cse_id: String,
        role: u8,
    }

    public struct NodeDeregistered has copy, drop {
        node_addr: address,
    }

    // === Init ===
    fun init(ctx: &mut TxContext) {
        let cap = AdminCap { id: object::new(ctx) };
        transfer::public_transfer(cap, tx_context::sender(ctx));

        let registry = Registry {
            id: object::new(ctx),
            nodes: table::new<address, Node>(ctx),
        };
        // Share so every PTB can read.
        transfer::share_object(registry);
    }

    // === Admin operations ===
    public fun register(
        _admin: &AdminCap,
        registry: &mut Registry,
        node_addr: address,
        cse_id: String,
        role: u8,
        registered_at_ms: u64,
    ) {
        assert!(!table::contains(&registry.nodes, node_addr), E_ALREADY_REGISTERED);

        let entry = Node {
            cse_id,
            role,
            registered_at_ms,
        };
        let cse_id_copy = entry.cse_id;
        table::add(&mut registry.nodes, node_addr, entry);

        event::emit(NodeRegistered {
            node_addr,
            cse_id: cse_id_copy,
            role,
        });
    }

    public fun deregister(
        _admin: &AdminCap,
        registry: &mut Registry,
        node_addr: address,
    ) {
        assert!(table::contains(&registry.nodes, node_addr), E_NOT_REGISTERED);
        let _ = table::remove(&mut registry.nodes, node_addr);

        event::emit(NodeDeregistered { node_addr });
    }

    // === PTB step 1: Identity ===
    // Called inside every access PTB. Aborts if `claimed` is not in the
    // registry, which rolls back the whole 6-step transaction.
    public fun verify(registry: &Registry, claimed: address) {
        assert!(table::contains(&registry.nodes, claimed), E_NOT_REGISTERED);
    }

    // === Reads (used by other modules and by clients) ===
    public fun is_registered(registry: &Registry, node_addr: address): bool {
        table::contains(&registry.nodes, node_addr)
    }

    public fun role_of(registry: &Registry, node_addr: address): u8 {
        let node = table::borrow(&registry.nodes, node_addr);
        node.role
    }

    public fun cse_id_of(registry: &Registry, node_addr: address): String {
        let node = table::borrow(&registry.nodes, node_addr);
        node.cse_id
    }

    // === Role constants ===
    public fun role_in_cse(): u8 { ROLE_IN_CSE }
    public fun role_mn_cse(): u8 { ROLE_MN_CSE }
    public fun role_ae():     u8 { ROLE_AE }
}
