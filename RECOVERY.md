# Testbed Recovery Runbook

How to bring the OM2M-Sui cluster back up after nodes go down (e.g. reboot,
power loss). Written after a full recovery on 2026-06-22 where all three nodes
had been down ~2 weeks and lost runtime config to a /tmp wipe.

## Nodes
- rpi3 = 10.25.96.203 = IN-CSE parent, addr 0x27dacda1...64ea10 (stable node)
- rpi1 = 10.25.96.200 = MN-CSE follower, addr 0xef9c6271...e1d5f9
- rpi2 = 10.25.96.201 = MN-CSE follower, addr 0x4be6060a...3dc1f5
- SSH: sshpass -p user ssh user@<ip>   (sudo password also "user")
- Container: om2m-active   Broker: mosquitto (per node)

## The four breakages seen on recovery (fix all four)

### 1. /tmp config wiped on reboot
The Docker mounts source three runtime files from /tmp, which does not survive
reboot. Docker then recreates the missing mount sources as ROOT-OWNED EMPTY
DIRECTORIES, which blocks the file mounts (container won't start: "not a
directory"). Durable copies live in ~/sui-runtime-config/ on each node.

Fix (needs sudo - the stale dirs are root-owned):
    sudo rm -rf /tmp/sui.properties /tmp/sui.mappings.properties /tmp/current-parent-poa
    sudo cp ~/sui-runtime-config/sui.properties /tmp/sui.properties
    sudo cp ~/sui-runtime-config/sui.mappings.properties /tmp/sui.mappings.properties
    sudo mkdir -p /tmp/current-parent-poa      # NOTE: this one is a DIRECTORY mount, not a file

### 2. client.yaml has host paths, not container paths
~/.sui/sui_config/client.yaml stores keystore paths as /home/user/.sui/... but
inside the container the mount lands at /root/.sui/sui_config/. The CLI then
cannot find/write its keystore and every `sui client call` exits 1.

Fix:
    sed -i 's#/home/user/.sui/sui_config#/root/.sui/sui_config#g' ~/.sui/sui_config/client.yaml
(Trade-off: this breaks running `sui` directly on the host as user. The
in-container plugin is what matters, so keep it pointed at /root/...)

### 3. sui_config mounted read-only
The CLI rewrites client.yaml on EVERY call. If the sui_config volume is mounted
:ro the call fails with "Read-only file system (os error 30)". active-address
still works (read-only) which is misleading - only `call` fails.
Fix: the container must mount sui_config :rw (see run command below).

### 4. OM2M resource DB is in-memory
The sui-das AE and protected container do NOT survive a container restart/
recreate. Recreate them after every boot (see step 4 below).

## Full recovery sequence (per node)

### Step 1 - restore /tmp config (see breakage 1 above, needs sudo)

### Step 2 - fix client.yaml paths (see breakage 2 above)

### Step 3 - (re)create the container with sui_config :rw
For rpi3 (IN-CSE). Adjust CSE_TYPE/image/node for followers.
    sudo docker rm -f om2m-active
    sudo docker run -d --name om2m-active --network bridge \
      -p 8282:8282 -p 8080:8282 \
      -e DEBIAN_FRONTEND=noninteractive -e SKIP_MN_SYNC=true \
      -e SKIP_ARM64_REGISTRATION=false -e CSE_TYPE=IN \
      -e ONEM2M_ID=in-cse -e LOCAL_MN_CSE_ID=mn-cse -e LOCAL_MN_CSE_NAME=mn-name \
      -v /home/user/.sui/sui_config:/root/.sui/sui_config:rw \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v /tmp/sui.properties:/root/git/org.eclipse.om2m/org.eclipse.om2m.site.mn-cse/target/products/mn-cse/linux/gtk/aarch64/configuration/sui.properties \
      -v /tmp/sui.mappings.properties:/root/git/org.eclipse.om2m/org.eclipse.om2m.site.mn-cse/target/products/mn-cse/linux/gtk/aarch64/configuration/sui.mappings.properties \
      -v /tmp/current-parent-poa:/tmp/current-parent-poa \
      mouazkass/om2m-sui-in:rpi1 8282 in-cse 9090

### Step 4 - recreate OM2M resources (in-memory DB, lost on recreate)
    curl -s -X POST 'http://127.0.0.1:8282/~/in-cse/in-name' -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-RI: a1' -H 'Content-Type: application/json;ty=2' -d '{"m2m:ae":{"rn":"sui-das","api":"N.sui-das.0001","apn":"sui-das","poa":["sui-das"],"rr":true}}'
    curl -s -X POST 'http://127.0.0.1:8282/~/in-cse/in-name' -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-RI: c1' -H 'Content-Type: application/json;ty=3' -d '{"m2m:cnt":{"rn":"sui-protected-cnt"}}'

### Step 5 - verify
    docker exec om2m-active sui client active-address      # -> node address
    curl ... /~/in-cse                                     # -> 200
    # GRANT smoke test (expect Sui GRANT ... digest):
    curl -s -X POST '.../sui-das' ... or:"Csensor-001" op:1 rid:sui-protected-cnt
    docker logs --since 25s om2m-active | grep 'Sui GRANT'

## Known cosmetic noise (not fatal)
- "Target is not reachable http://127.0.0.1:8080/~/in-cse ... Retrying in 10s"
  IN-CSE trying to register upward; logs every 10s but OM2M serves fine.
  This is the FM4 / registration-reconciliation item, tracked separately.

## Config values (source of truth = git + transcript)
package    0x7208dd4bcd25a69007317185524538cc44f00909a9bce8a9ea0b0976a30ad099
identity   0x7cce2b1269d1b654c0df180eab39e6f23bcc4f1b15b8327678467d702d460375
trust      0xce9bb88e09fa044eca1365f167cab3e12ed427429a311c1bf1bd96b08cfbef0f
policy     0x621e7f65f9e9125ee7d50d08dc4108d30c7e8924353c131f3c2d0da31935a77c
audit      0x433a99d49718a69af7ac22fc9adae43b10373b1c5f81ea7df4a037b8b80db32f
cluster    0x2ca259ed6a30f0a9dd8b4950789331654f12836f179b82c7fbb52c74476a3800
clock      0x6   gas budget 20000000   mqtt tcp://<own-ip>:1883

## FM4 — cseType must be "in-cse" (not "IN")
config.ini is baked in the image (NOT host-mounted). OM2M's CSEType.IN constant
is the string "in-cse". If config.ini has `org.eclipse.om2m.cseType=IN`, the
IN-CSE check fails ("IN" != "in-cse") and the node loops on upstream registration
(5103 every 10s).
On container recreation from the base image, EITHER:
  - recreate from the per-node fixed image: mouazkass/om2m-sui-in:rpiN-incse, OR
  - re-apply: sed -i 's/^org.eclipse.om2m.cseType=IN$/org.eclipse.om2m.cseType=in-cse/' \
      .../configuration/config.ini  (then docker restart)
Verify: in-cse=200 and `docker logs | grep -c 5103` == 0.
## DAS Provisioning & the External-NOTIFY Blocker (findings 2026-06-27)

### TL;DR
The external HTTP NOTIFY path to `sui-das` is **blocked by OM2M's router**
(`Controller.checkACP`, Controller.java:212, "Current resource does not have any
ACP attached") on BOTH rpi1 and rpi3, regardless of how the ACP is configured.
The NOTIFY never reaches `SuiDasService.doExecute` — it dies in the router first.
A live GRANT could NOT be re-triggered via curl this session.

### What was verified to work
- rpi3 mappings correctly point Csensor-001 -> rpi3's own address (0x27dacda1...),
  and the CapToken 0xe474652c... IS owned by rpi3. So the token-owner-matches-node
  constraint is satisfied on rpi3 (it is NOT on rpi1 — rpi1 is the cross-node
  DENIAL test node; its mapping points Csensor-001 at rpi1 but the token is rpi3's).
- rpi3 is on v6 (sui.package.id=0xb579914d...). Mappings persist in
  sui.mappings.properties (mounted from /tmp, durable copy in ~/sui-runtime-config/).
- The DAS registers fine as an InterworkingService (activator logs "DAS registered
  at APOC path: sui-das"). Plugin loads, failover works, trust engine starts.

### The OM2M resource situation (all in-memory, lost on every restart)
After ANY container restart you must recreate, on the node you're testing:
1. sui-das AE (ty=2) — MUST include acpi at POST time (see ACP-bootstrapping below)
2. sui-protected-cnt container (ty=3) — same acpi requirement
The ACP resource (acp_admin) survives as /in-cse/acp-XXXXXXXXX but its `ri` is
**regenerated on every boot** — discover it fresh by reading
`/~/in-cse/in-name/acp_admin` and taking `m2m:acp.ri`. Do NOT hardcode the acp-id.

### ACP bootstrapping lockout (important)
A resource created with NO acp denies its own UPDATE and DELETE ("Unknown or
unauthorized originator" / "no ACP attached"). So you CANNOT attach an ACP after
the fact via PUT, and you cannot delete-and-recreate. You MUST set `acpi` at
creation (POST) time. Creating WITH acpi works (returns 201 with acpi populated).

### The blocker (unresolved)
Even with:
  - resources created WITH acpi from birth (201, acpi confirmed in body),
  - the ACP updated so Csensor-001 has acop=63 (200, confirmed),
  - the ACP resolving correctly (GET acp-XXXX returns 200),
...a NOTIFY to /~/in-cse/in-name/sui-das STILL returns 403 "no ACP attached",
and the log shows the RequestPrimitive is BUILT and routed to sui-das but
`doExecute` is NEVER reached. The denial is in OM2M's core Router/Controller,
before the plugin runs.

### Why this matters / hypotheses for next session
POLICY_EVIDENCE.md line 6 says the working GRANTs were "triggered by NOTIFYs to
the sui-das PoA" — i.e. this same path. Yet it now fails on every node. Either:
  (a) A provisioning step is still missing that the original session had.
  (b) The OM2M image/config differed when those GRANTs were captured.
  (c) The GRANTs were actually fired through the in-JVM Redirector
      (DynamicAuthorizationConsultation/Selector) path, NOT external HTTP NOTIFY —
      and the external path never truly worked. The DAS source explicitly calls
      the HTTP NOTIFY a "test/external path" and the DAC-RETRIEVE the production
      path. No DynamicAuthorizationConsultation class was found in the container,
      so this OM2M build may not support DAC resources at all — which would mean
      the in-JVM path was triggered some other way (e.g. direct Redirector
      injection in a test harness), not reproducible via curl.

### To resolve (focused session, at the machine, ideally with Hamza)
1. Decompile/read OM2M core Controller.checkACP (Controller.java:212) from the
   container to see the EXACT condition that throws "no ACP attached" for a
   NOTIFY-to-AE. The .class is in the container; the .java may not be.
2. Recover how the original rpi3 GRANTs were actually triggered — check rpi3
   shell history, any test harness/script, or ask Hamza. This is the keystone.
3. If the answer is in-JVM only: document that external curl-NOTIFY is not a
   supported trigger, and that GRANTs require the in-JVM path (and how to invoke
   it). If external SHOULD work: find the missing provisioning step.

### Not a paper blocker
On-chain access logic is independently proven (real GRANTs/DENYs with correct
abort codes, capability isolation across nodes) in the evidence files, and the
Evaluation section has five real measured numbers. Re-triggering a live GRANT is
a system-reliability task, not a prerequisite for the written paper.

## WORKING GRANT TRIGGER (verified 2026-06-27, rpi3, v6)
The external NOTIFY path REQUIRES the X-M2M-Operation: 5 header. Without it,
OM2M routes the POST through normal checkACP and returns 403. With it, the
request reaches SuiDasService.doExecute and the on-chain check runs.

# After recreating sui-das AE + sui-protected-cnt (with acpi from birth), fire:
curl -s -w "\nHTTP %{http_code}\n" -X POST "http://127.0.0.1:8282/~/in-cse/in-name/sui-das" \
  -H "X-M2M-Origin: admin:admin" -H "X-M2M-RI: fire" \
  -H "X-M2M-Operation: 5" -H "Content-Type: application/json" \
  -d '{"m2m:sec":{"sit":1,"dreq":{"or":"admin:admin","op":1,"rid":"/in-cse/in-name/sui-protected-cnt","rty":3}}}'
# Expect: HTTP 200 + "Sui GRANT ... (NNNN ms)" in docker logs.
# Steady-state latency ~1.4s on v6.
