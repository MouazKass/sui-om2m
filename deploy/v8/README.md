# deploy/v8 - generated v8 deployment state

Everything in this directory is produced by `scripts/v8/*`. Do not edit it by hand; fix the script or `deployment.env` and regenerate.

| Step | Script | Signs? | Writes |
|---|---|---|---|
| C. Publish | `scripts/v8/01_publish.sh [--execute]` | yes (publisher) | `publish.json`, `deployment.env` |
| D. Bootstrap | `scripts/v8/02_bootstrap.sh [--plan\|--simulate\|--execute]` | only with `--execute` | appends ids and digests to `deployment.env`; raw CLI output goes to `bootstrap/` |
| E. Config | `scripts/v8/03_gen_config.sh` | never | `nodes/rpi{1,2,3}/sui.properties`, `nodes/rpi{1,2,3}/sui.mappings.properties`, `env.v8.sh` |

**Since v9 (2026-11-10):** `01 --execute` is refused while `deployment.env` exists (the live v9 package is an upgrade of this one and its types keep the v8 id); `01 --execute --fresh-publish` writes a separate deployment to `deploy/fresh-<UTC>/`. `02 --simulate/--execute` against this directory is refused (the council holds the caps; see `scripts/lib/legacy_guard.sh`), `02 --plan` still works. `03` is unaffected and is still how node configs are generated.

All three run in WSL on the publisher machine. `02` and `03` accept `DEPLOY_ENV=<path>`, and `03` also accepts `OUT_DIR=<dir>` for dry runs against a scratch copy.

## deployment.env
This file is the single source of truth. `01` writes the package, the registries (with `_ISV`), and the publisher caps. `02` appends:

- `TRUST_ADMIN_CAP_RPI{1,2,3}`: each node's own trust AdminCap. Each one is in the TR7 validity set, so each can be revoked on its own.
- `TOKEN_SUI_PROTECTED_CNT` and `TOKEN_SUI_DAC_AE`: the CapTokens. Both are owned by rpi3, and `BOOT_TOKEN_EXPIRY_MS` records their expiry.
- `CLUSTER`, `CLUSTER_ISV` and `CLUSTER_ADMIN_CAP`.
- A `<STEP>_TX` digest for every bootstrap transaction. This is the idempotency marker: a step whose output or digest is already recorded is never re-run.

## Timing notes
- `create_cluster` runs last. The `EE_5` lease (default 20 min) starts when the cluster is created. If cutover (phase F) happens later than that, the lease will already have expired when the nodes come up, and any registered node with trust >= 50 can claim parent.
- Trust decays lazily, by 1 point per day without a write (`trust.move` `DECAY_PER_DAY`). With the default starting score of 80 and gate/min_trust of 50, a node that never gets an on-chain score write falls to the gate after about 30 days.
- CapTokens expire 180 days after minting by default (`TOKEN_DAYS`).

## Installing (phase E, by hand)
Copy `nodes/rpiN/*` to `~/sui-runtime-config/` on each Pi first. Then copy them to `/tmp/`, which is the bind-mount source. Keep the v7 files as `v7-backup-<date>`. See `ROLLOUT_V8.md` and `RECOVERY.md`.
