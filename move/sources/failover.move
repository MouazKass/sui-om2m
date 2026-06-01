// failover.move
//
// Trust-Gated Parent Failover (slide 10).
//
// This is a SECONDARY contribution and architecturally INDEPENDENT of
// the three-layer access control framework on slides 7-9. The framework
// runs on every access request; failover runs only when an MN-CSE
// parent dies.
//
// The flow on slide 10:
//
//   1. NORMAL OPERATION    : parent sends MQTT heartbeats (off-chain).
//   2. MQTT HEARTBEAT      : received within window -> stay in (1).
//   3. FAILURE SUSPECTED   : missed window -> eligible nodes may claim.
//   4. TRUST GATE          : claim accepted iff node registered AND
//                            trust >= threshold.
//   5. MULTIPLE CLAIMS?    : if yes, Sui's tx ordering picks one
//                            deterministically. If no, immediate elect.
//   6. NEW PARENT ELECTED  : winner becomes current_parent on-chain,
//                            lease reset, returns to (1) over MQTT.
//
// Trust check is shared with the framework's trust.move — same registry,
// two readers. That's intentional: one source of truth for "is this
// node trustworthy?".

module om2m_access::failover {
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::clock::{Self, Clock};
    use sui::event;

    use om2m_access::identity::{Self, Registry as IdentityRegistry};
    use om2m_access::trust::{Self, TrustRegistry};

    // === Errors ===
    const E_NOT_REGISTERED:     u64 = 1;
    const E_TRUST_BELOW_GATE:   u64 = 2;
    const E_LEASE_STILL_VALID:  u64 = 3;
    const E_NOT_PARENT_ROLE:    u64 = 4;
    const E_SAME_PARENT:        u64 = 5;
    const E_NOT_PARENT:         u64 = 6;

    // === Cluster (shared object — one per failover group) ===
    // A cluster is the set of MN-CSEs that share a parent (and possibly
    // the IN-CSE itself, for top-level failover). The current_parent
    // address is updated on every successful takeover.
    public struct Cluster has key {
        id: UID,
        // Stable cluster identifier (mirrors OM2M "EE_5"-style cluster
        // labels from Hammad et al.'s prior work).
        cluster_id: vector<u8>,
        // Sui address of the currently-leading parent node.
        current_parent: address,
        // Wall-clock time the current lease expires. The proxy renews
        // by emitting MQTT heartbeats off-chain; this on-chain value is
        // only consulted when a takeover is attempted.
        lease_expires_ms: u64,
        // Trust threshold a candidate must clear. Settable per-cluster.
        trust_gate: u64,
        // Monotonic counter for tie-breaks if multiple PTBs land in the
        // same checkpoint.
        epoch: u64,
    }

    // === Capability (admin can adjust the trust gate / lease length) ===
    public struct ClusterAdminCap has key, store {
        id: UID,
        cluster: address, // which cluster this cap administers
    }

    // === Events ===
    public struct ClusterCreated has copy, drop {
        cluster: address,
        cluster_id: vector<u8>,
        initial_parent: address,
        trust_gate: u64,
    }

    public struct LeaseRenewed has copy, drop {
        cluster: address,
        parent: address,
        new_expires_ms: u64,
    }

    public struct TakeoverAttempted has copy, drop {
        cluster: address,
        candidate: address,
        candidate_trust: u64,
        accepted: bool,
        timestamp_ms: u64,
    }

    public struct ParentChanged has copy, drop {
        cluster: address,
        old_parent: address,
        new_parent: address,
        epoch: u64,
        timestamp_ms: u64,
    }

    // === Cluster lifecycle ===
    public fun create_cluster(
        cluster_id: vector<u8>,
        initial_parent: address,
        trust_gate: u64,
        initial_lease_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let now = clock::timestamp_ms(clock);
        let cluster = Cluster {
            id: object::new(ctx),
            cluster_id,
            current_parent: initial_parent,
            lease_expires_ms: now + initial_lease_ms,
            trust_gate,
            epoch: 0,
        };
        let cluster_addr = object::uid_to_address(&cluster.id);

        // Issue an admin cap tied to this cluster.
        let cap = ClusterAdminCap {
            id: object::new(ctx),
            cluster: cluster_addr,
        };
        transfer::public_transfer(cap, tx_context::sender(ctx));

        event::emit(ClusterCreated {
            cluster: cluster_addr,
            cluster_id: cluster.cluster_id,
            initial_parent,
            trust_gate,
        });

        transfer::share_object(cluster);
    }

    // === Off-chain heartbeat anchor ===
    // The MQTT heartbeat lives off-chain (slide 10 OFF-CHAIN box). The
    // proxy *occasionally* anchors a renewal on-chain — say, every 10
    // minutes — to keep `lease_expires_ms` from going stale and to
    // create a public, auditable liveness trail. This is optional; the
    // takeover path also works if the chain has never seen a renewal.
    public fun renew_lease(
        cluster: &mut Cluster,
        new_lease_ms: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        // Only the current parent can renew its own lease.
        let sender = tx_context::sender(ctx);
        assert!(sender == cluster.current_parent, E_NOT_PARENT_ROLE);

        let now = clock::timestamp_ms(clock);
        cluster.lease_expires_ms = now + new_lease_ms;

        event::emit(LeaseRenewed {
            cluster: object::uid_to_address(&cluster.id),
            parent: sender,
            new_expires_ms: cluster.lease_expires_ms,
        });
    }

    // === Takeover claim ===
    // This is the on-chain entry point of slide 10's failover flow.
    // Called by a candidate MN-CSE once its proxy has noticed missed
    // MQTT heartbeats. Sui's transaction ordering deterministically
    // picks one winner if multiple candidates race.
    //
    // The trust gate is checked against the *same* trust registry the
    // 6-step PTB uses, so a node's reputation has consequences in both
    // hot paths.
    public fun claim_parent(
        cluster: &mut Cluster,
        identity_reg: &IdentityRegistry,
        trust_reg: &TrustRegistry,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let candidate = tx_context::sender(ctx);
        let now = clock::timestamp_ms(clock);

        // Lease must actually have expired. Sui's deterministic ordering
        // resolves the "multiple claims" branch on slide 10: only the
        // first PTB to clear this guard updates state; the rest see the
        // updated lease and abort.
        assert!(now >= cluster.lease_expires_ms, E_LEASE_STILL_VALID);

        // Trust Gate — Part 1: must be a known node.
        if (!identity::is_registered(identity_reg, candidate)) {
            event::emit(TakeoverAttempted {
                cluster: object::uid_to_address(&cluster.id),
                candidate,
                candidate_trust: 0,
                accepted: false,
                timestamp_ms: now,
            });
            abort E_NOT_REGISTERED
        };

        // Trust Gate — Part 1.5: must be of a parent-eligible role
        // (MN-CSE or IN-CSE, never an AE).
        let role = identity::role_of(identity_reg, candidate);
        if (role != identity::role_mn_cse() && role != identity::role_in_cse()) {
            event::emit(TakeoverAttempted {
                cluster: object::uid_to_address(&cluster.id),
                candidate,
                candidate_trust: 0,
                accepted: false,
                timestamp_ms: now,
            });
            abort E_NOT_PARENT_ROLE
        };

        // Trust Gate — Part 2: score >= threshold.
        let score = trust::score_of(trust_reg, candidate, clock);
        if (score < cluster.trust_gate) {
            event::emit(TakeoverAttempted {
                cluster: object::uid_to_address(&cluster.id),
                candidate,
                candidate_trust: score,
                accepted: false,
                timestamp_ms: now,
            });
            abort E_TRUST_BELOW_GATE
        };

        // No-op if somehow the same node is reclaiming itself
        // (shouldn't happen but guards against PTB replay glitches).
        assert!(candidate != cluster.current_parent, E_SAME_PARENT);

        let old_parent = cluster.current_parent;
        cluster.current_parent = candidate;
        cluster.epoch = cluster.epoch + 1;
        // Fresh lease — short, since the new parent will renew via MQTT
        // anchor shortly. 60_000 ms = one minute.
        cluster.lease_expires_ms = now + 60_000;

        event::emit(TakeoverAttempted {
            cluster: object::uid_to_address(&cluster.id),
            candidate,
            candidate_trust: score,
            accepted: true,
            timestamp_ms: now,
        });

        event::emit(ParentChanged {
            cluster: object::uid_to_address(&cluster.id),
            old_parent,
            new_parent: candidate,
            epoch: cluster.epoch,
            timestamp_ms: now,
        });
    }

    // === Admin: adjust the trust gate ===
    public fun set_trust_gate(
        cap: &ClusterAdminCap,
        cluster: &mut Cluster,
        new_gate: u64,
    ) {
        // Cap must be for this cluster.
        assert!(cap.cluster == object::uid_to_address(&cluster.id), E_NOT_REGISTERED);
        cluster.trust_gate = new_gate;
    }

    // === Reads ===
    public fun current_parent(cluster: &Cluster): address { cluster.current_parent }
    public fun lease_expires_ms(cluster: &Cluster): u64   { cluster.lease_expires_ms }
    public fun trust_gate(cluster: &Cluster): u64         { cluster.trust_gate }
    public fun epoch(cluster: &Cluster): u64              { cluster.epoch }


    /// Dynamic field key for storing the parent's advertised PoA on
    /// the Cluster object. Using a dynamic field lets us extend the
    /// cluster's state without breaking upgrade compatibility on the
    /// Cluster struct. This is the same Layer 3 mechanism (Dynamic
    /// Fields) used for CapToken use-counter accounting.
    public struct ParentPoaKey has copy, drop, store {}

    /// Called by the active parent after it has come up as IN-CSE,
    /// to advertise its HTTP(S) PoA to followers. Only the current
    /// parent may call this; any other sender aborts.
    public entry fun set_parent_poa(
        cluster: &mut Cluster,
        new_poa: vector<u8>,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == cluster.current_parent, E_NOT_PARENT);
        let key = ParentPoaKey {};
        if (sui::dynamic_field::exists(&cluster.id, key)) {
            let old: vector<u8> = sui::dynamic_field::remove(&mut cluster.id, key);
            let _ = old;
        };
        sui::dynamic_field::add(&mut cluster.id, key, new_poa);
    }

    /// Read the currently advertised PoA for the cluster (for followers).
    /// Returns empty vector if no PoA has been set yet.
    public fun parent_poa(cluster: &Cluster): vector<u8> {
        let key = ParentPoaKey {};
        if (sui::dynamic_field::exists(&cluster.id, key)) {
            *sui::dynamic_field::borrow<ParentPoaKey, vector<u8>>(&cluster.id, key)
        } else {
            vector[]
        }
    }
}
