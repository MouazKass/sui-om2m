# Rollout v9 on the 5-node testbed: DRAFT PLAN

Status, 2026-11-10: **draft. Nothing in this file has been executed on the Pis or
on-chain.** The live testbed is still v8 on rpi1–3. The design, its tests and the
step-by-step multisig runbook are in [V9_DESIGN.md](V9_DESIGN.md); this file is the
order of operations for the cluster as it now is.

## What changed since V9_DESIGN.md was written

1. **The cluster is growing from 3 to 5 nodes.** rpi4 (`rpi4-iot`, 10.25.96.204) and rpi5
   (`rpi5-iot`, 10.25.96.205), both Pi 5 16 GB, are listed in `deploy/inventory.tsv` as
   `status=pending`. They were unreachable when this was written: no ping, no SSH.
2. **Option A was chosen for the UpgradeCap.** The publisher keeps it for now. The 2-of-3
   multisig (V9_DESIGN.md §5, phases C–D) is postponed, not dropped.
3. **Everything is driven by the inventory.** Config generation, cutover, mesh, proofs,
   bench and the v9 scripts all read `deploy/inventory.tsv` through
   `scripts/lib/inventory.sh`. For the existing 3 nodes the generated output is
   byte-identical to before, apart from the timestamp line. The generated mesh matches the
   live `mosquitto-mesh.conf` on rpi1–3 byte for byte.
4. **The council is formed with all 5 nodes, threshold 3** (strict majority).
   `scripts/v9/04_council.sh` takes the members from the inventory, defaults k to
   floor(n/2)+1, and refuses to run while any node is still pending or staged.
5. **A trust-aggregation bug that only shows with an even number of observers was fixed**
   (plugin, `TrustScoringEngine.agreementThreshold`). It was k = floor((n−1)/2)+1, which
   is exactly half when n is even. With 5 nodes every target has 4 observers, so k was 2,
   and two colluding observers could zero an honest node's garbage signal. It is now
   k = floor(n/2)+1. The new tests are mutation-checked: the old formula fails 3 of them.

## Order of operations

| # | Step | Command | Where | Signs |
|---|---|---|---|---|
| 0 | N-node tooling | (this commit) | local | — |
| 1 | Make rpi4/rpi5 reachable | power, network/VPN, then `! ssh-copy-id -i ~/.ssh/id_ed25519_suiom2m.pub user@<ip>` | Mouaz | — |
| 2 | Off-chain onboarding | `scripts/onboard_node.sh rpi4 offchain` (then rpi5) | Git Bash | — |
| 3 | On-chain admission on **v8** | `onboard_node.sh rpiN onchain-register \| onchain-trust \| onchain-cap --execute` | WSL (publisher) | publisher, 3 tx per node |
| 4 | Finish | `onboard_node.sh rpiN finish` (config, deploy, host, fund, mesh, verify) | Git Bash | node gas (faucet) |
| 5 | 5-node checks | `04_cutover.sh verify`; proof 06 (failover) on 5 nodes; one reboot test on rpi4 | Git Bash | node keys |
| 6 | Upgrade to v9 | `scripts/v9/02_upgrade.sh`, **direct publisher mode (still to be written)**; dry run first (≈ 0.207 SUI) | WSL | publisher |
| 7 | Point the plugin at v9 | `scripts/v9/03_switch_plugin.sh v9` (all active nodes) | Git Bash | node keys |
| 8 | Arm governance, 3-of-5 | `scripts/v9/04_council.sh` (dry run), then `--execute` | WSL | publisher, **one-way** |
| 9 | Verify | `scripts/v9/05_verify.sh` (member count = 5, threshold = 3, peer-revoke attack → `E_GOVERNED`) | WSL | — |
| 10 | Later: multisig UpgradeCap | V9_DESIGN.md §5 phases C–D | three signers | — |

**Why onboarding comes before the council (steps 3 → 8).** Before governance the
publisher admits a node with three ordinary transactions. Afterwards each admission is a
k-of-n proposal by member nodes (`ACT_ID_REGISTER`, `ACT_TRUST_ADD_NODE`,
`ACT_TRUST_GRANT_ADMIN`, then `ACT_ADD_MEMBER`). `scripts/onboard_onchain.sh` detects an
armed council, stops, and prints those proposals instead. Forming the council once, with
all 5 members, avoids a 3-member council that then has to vote twice on each new member,
and raise its threshold, before it reaches 5.

**Why step 6 is not yet runnable.** `scripts/v9/02_upgrade.sh` only implements the
multisig path (build → combine → execute). Option A needs a direct publisher-signed mode.
It is the same `sui client upgrade` with the publisher as sender, and must still use the
temporary-copy build so `move/Move.lock` is never rewritten from Windows.

## Facts the plan relies on

- **Membership is on-chain, not a list in the plugin.** B10 admits a gossip observer only if
  `identity::is_registered`. Heartbeats and gossip subscribe to `.../<cluster>/+`. The
  failover `Cluster` object has no member list (a claim needs registration and trust
  ≥ the gate). So a registered, deployed node is a full member with no plugin change.
- **The mesh is per-origin and out-only** (`deploy/mosquitto/gen-mesh-conf.sh`). Each
  broker has one bridge per other active node: 4 on a 5-node cluster, 20 one-way bridges
  in total. There is no loop at any size, and adding a node means regenerating every
  broker's config (`04_cutover.sh mesh`).
- **The quorum module already supports 5 members.** `assert_threshold_ok` requires
  k ≥ 2, k ≤ n and 2k > n. New tests: `five_member_council_is_three_of_five`,
  `revoke_admin_with_three_of_five`, `two_of_five_is_not_quorum` (abort 4) and
  `five_member_council_with_threshold_two_rejected` (abort 7). Move suite: 141/141.
- **New nodes have no v7 history.** `04_cutover.sh prepare` builds `:<name>-v8` from
  `:<name>-base` (the donor's v7-final OM2M image, copied by `onboard_node.sh images`), and
  never snapshots a v8 container as "v7-final". `rollback` leaves such a node on v8.

## Honest limits at n = 5

- **Median breakdown.** The 7 value signals use the median of the observers' reports. With
  4 observers per target the median tolerates 1 arbitrary reporter. With 2 colluding
  reporters it can move halfway towards their value, though no further: it is the mean of
  the two middle samples. The garbage flag (now a strict majority, 3 of 4) does tolerate 2.
  The 3-node cluster was weaker still: a median of 2 observers tolerates 0.
- **The DAS stays a single node.** rpi3 owns every CapToken (A3/A4: token owner = signer =
  requester). Adding nodes adds failover and trust capacity, not DAS redundancy. Per-node
  tokens are a separate design question.
- **Proof 06 actors.** The claimer and racer are now "the next two active nodes after the
  parent, in inventory order". This matches the old fixed table when rpi1 or rpi2 is
  parent. When rpi3 is parent the claimer is now rpi1, where it used to be rpi2.
