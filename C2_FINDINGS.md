# C2 — Is on-chain authorization of ordinary oneM2M requests achievable on this stack?

**Verdict: YES. C2 is achievable, and it has been implemented on branch `security-fixes-v8`.**

The feature the project needs — `<dynamicAuthorizationConsultation>` and its enforcement
hook — genuinely exists in the Eclipse OM2M codebase that `plugin/pom.xml` pins, and the
existing `SuiDasService` is already registered the way OM2M's own DAS conformance suite
registers a DAS. What was missing was **provisioning**, not code: there was no
`<dynamicAuthorizationConsultation>` resource anywhere, and the ACP protecting the test
resource granted `acop=63` statically, so the consultation hook could never fire.

This document records the evidence, the four non-obvious constraints that dictate *how* it
must be wired, what changed, and a decisive on-hardware test.

> **Confidence.** High for everything derived from the oneM2M specifications and from
> reading real OM2M source (cited by file and line below), and for the fact that
> `plugin/` type-checks against real OM2M sources. **Not verified on hardware** — there is
> no live CSE in this environment. Nothing here claims a passing on-device test. Run
> `scripts/verify_c2_dac.sh` to confirm or refute on the Pi; it is built to do exactly that.

---

## 1. What the standard says

Sources:

- oneM2M TS-0001 / ETSI TS 118 101, *Functional Architecture* —
  <https://www.onem2m.org/images/files/deliverables/Release2/TS-0001-%20Functional_Architecture-V2_10_0.pdf>
- oneM2M TS-0003 / ETSI TS 118 103 v2.12.1, *Security Solutions*, clause 7.3 —
  <https://www.etsi.org/deliver/etsi_ts/118100_118199/118103/02.12.01_60/ts_118103v021201p.pdf>
- oneM2M TR-0019, *Dynamic Authorization* —
  <https://www.onem2m.org/images/files/deliverables/Release2/TR-0019-Dynamic_Authorization-V2_0_0.pdf>

**Resource type.** `<dynamicAuthorizationConsultation>` is **resource type 34**, short name
`dac`. Its attributes are `dynamicAuthorizationEnabled` (`dae`, **mandatory**, cardinality 1),
`dynamicAuthorizationPoA` (`dap`), and `dynamicAuthorizationLifetime` (`dal`).

**How a resource references it.** Not through the ACP. An ordinary resource carries the
common attribute `dynamicAuthorizationConsultationIDs` (short name **`daci`**), a list of
identifiers linking it to `<dynamicAuthorizationConsultation>` resources. TS-0001:

> "For a resource that is not of `<dynamicAuthorizationConsultation>` resource type, the
> common attribute `dynamicAuthorizationConsultationIDs` for such resources … may contain a
> list of identifiers which link that resource to `<dynamicAuthorizationConsultation>`
> resources."

**The decisive semantic — consultation happens only on static-check failure.** TS-0001,
Access Control Decision:

> "In the event that the requesting entity **does not satisfy the owner's access control
> policy**, a Hosting CSE shall check to see if the resource (**or one of its parents**) has a
> `dynamicAuthorizationConsultationIDs` which links to a valid
> `<dynamicAuthorizationConsultation>` resource. If there is no valid
> `<dynamicAuthorizationConsultation>` resource or if the `dynamicAuthorizationEnabled`
> attribute is set to "false", then … the Hosting CSE shall not attempt to perform direct
> dynamic authorization … However, if there is a valid `<dynamicAuthorizationConsultation>`
> resource and if the `dynamicAuthorizationEnabled` attribute is set to "true", then the
> Hosting CSE shall initiate a direct dynamic authorization request to the specified
> `dynamicAuthorizationPoA`. If direct dynamic authorization results in sufficient privileges
> being granted to the requesting entity, the Hosting CSE shall grant it access."

TS-0003 clause 7.3.2.2 says the same in the Direct Dynamic Authorization message flow —
step 2.1: *"The Hosting CSE evaluates the access decision algorithm, but **is unable to grant
access** for the request from the Originator based on configured access control policies"*;
step 2.2.2 collects the `<dynamicAuthorizationConsultation>` resources "linked to the
requested resource"; step 4.2: *"The Hosting CSE **repeats** the access decision mechanism"*.

**Answer to the question the task posed:** dynamic authorization is consulted **only when the
static ACP check fails**. It can therefore **only ever grant additional access — it can never
override or revoke a static grant.** The project's instinct was exactly right: making the Sui
DAS authoritative *requires* a static ACP that grants the originator nothing, plus a
consultation pointing at the DAS. A permissive ACP (`acop=63`, as `acp_admin` has today)
makes the DAS structurally unreachable.

---

## 2. Does Eclipse OM2M implement it? Yes — and the version string is a red herring

`plugin/pom.xml` pins `org.eclipse.om2m:*:1.1.0`, which naturally reads as "OM2M release
1.1.0" — a release that *would* predate dynamic authorization. That reading is wrong.

Evidence from the upstream repository (`https://gitlab.eclipse.org/eclipse/om2m/om2m.git`):

| git ref | root/bundle version | `Bundle-Version` | DAC implementation present? |
|---|---|---|---|
| `1.0.0` (2016-05) | `1.0.0-SNAPSHOT` | `1.0.0.qualifier` | **no** |
| `1.3.0` (2018-03) | `1.1.0-SNAPSHOT` | `1.1.0.qualifier` | yes |
| `1.4.0` (2020-06) | `1.1.0-SNAPSHOT` | `1.1.0.qualifier` | yes |
| `1.4.1` | `1.1.0-SNAPSHOT` | `1.1.0.qualifier` | yes |
| `1.5.0` (2025-11, = `master`) | `1.1.0-SNAPSHOT` | `1.1.0.qualifier` | yes |

Two facts follow:

1. **There is no OM2M 1.1.0 release.** The tag list is `0.8.0, 1.0.0, 1.3.0, 1.4.0, 1.4.1,
   1.5.0` — no `1.1.0`. The Maven/OSGi version has simply been frozen at `1.1.0` since the
   1.3.0 release. So `1.1.0` is the artifact version shared by releases **1.3.0 through
   1.5.0**, every one of which contains the full dynamic authorization stack.
2. The code was added by commit `6b25ebe1` (2017-04-14), *"all: send NOTIFY request to DAS's
   AE to perform dynamic authorization"* — i.e. during the 1.1.0-versioned development line,
   well before the 1.3.0 tag. The Eclipse 1.4.0 release notes advertise *"Implementation of
   Dynamic Authorization features as defined to oneM2M standard"*
   (<https://projects.eclipse.org/projects/iot.om2m/releases/1.4.0>), which is when it was
   announced rather than when it first landed.

**Classes that exist** (confirmed present at `1.3.0`, `1.4.0`, `1.4.1`, `1.5.0`, `master`):

| Class | Bundle |
|---|---|
| `org.eclipse.om2m.commons.resource.DynamicAuthorizationConsultation` | commons |
| `org.eclipse.om2m.commons.entities.DynamicAuthorizationConsultationEntity` | commons |
| `org.eclipse.om2m.commons.resource.{SecurityInfo, DynAuthDasRequest, DynAuthDasResponse}` | commons |
| `org.eclipse.om2m.core.dynamicauthorization.DynamicAuthorizationSelector` | core |
| `org.eclipse.om2m.core.controller.DynamicAuthorizationConsultationController` | core |
| `org.eclipse.om2m.core.entitymapper.DynamicAuthorizationConsultationMapper` | core |
| `…persistence.eclipselink.internal.dao.DynamicAuthorizationConsultationDAO` | persistence |
| `…persistence.service.util.DynamicAuthorizationConsultationUtil` | persistence SPI |
| `org.eclipse.om2m.das.service.DynamicAuthorizationServerService` | `org.eclipse.om2m.das.service` |
| `org.eclipse.om2m.das.testsuite.*` (a whole DAS conformance suite) | `org.eclipse.om2m.das.testsuite` |

`grep -ril "dynamicAuthorizationConsultation"` returning nothing **in this repo** was
accurate — but it was evidence about *this project*, not about OM2M.

### The enforcement hook

`org.eclipse.om2m.core/src/main/java/org/eclipse/om2m/core/controller/Controller.java`:

```java
public void checkPermissions(RequestPrimitive request, ResourceEntity resource,
        List<AccessControlPolicyEntity> acpList) throws AccessDeniedException {
    // check ACPs
    try {
        checkACP(acpList, request.getFrom(), request.getOperation());
        //return immediately if one ACP grants access
        return;
    } catch (AccessDeniedException e) {
        // nothing to do as we need to check DynamicAuthorizationConsultation
    }
    DynamicAuthorizationSelector.getInstance().authorize(
        dbs.getDBUtilManager().getDynamicAuthorizationConsultationUtil()
           .getDynamicAuthorizationConsultations(resource.getResourceID()),
        request, resource);
}
```

This is the standard's semantic implemented literally: static check first, DAC only on
failure. The full live chain is:

```
AEController.doRetrieve
  -> Controller.checkPermissions                       static ACP fails
  -> DynamicAuthorizationSelector.authorize(daces, …)  builds SecurityInfo
                                                       (DYNAMIC_AUTHORIZATION_REQUEST)
  -> Redirector.retargetNotify(NOTIFY, MimeMediaType.OBJ)
  -> IpeSelector.getInterworkingList().get(poa).doExecute(request)
  -> SuiDasService.doExecute                           in-JVM, typed SecurityInfo
```

`Redirector.retargetNotify` dispatches in-process when the AE's point of access matches a
registered `InterworkingService` APOC path:

```java
String poa = ae.getPointOfAccess().get(i);
if (IpeSelector.getInterworkingList().containsKey(poa)) {
    LOGGER.info("Sending notification to IPE: " + poa);
    response = IpeSelector.getInterworkingList().get(poa).doExecute(request);
}
```

`SuiPluginActivator` already does `ctx.registerService(InterworkingService.class, das, …)`,
which is byte-for-byte the registration used by OM2M's own
`org.eclipse.om2m.das.testsuite.ae.AbstractDASServiceTest`. **The DAS side was already
correct.** The class comments in `SuiDasService` describing a "Production path … delivers a
typed SecurityInfo object via in-JVM call" were accurate, and the `content instanceof
SecurityInfo` branch handles it.

---

## 3. Four non-obvious constraints that dictate the wiring

These are the reasons the obvious configuration would silently fail. Each is from OM2M source.

### 3.1 A `<container>` can NEVER be protected by a DAS on this stack

Only controllers that call `checkPermissions` consult DACs. Counting call sites:

| Controller | calls `checkPermissions` | DAC-enforced? |
|---|---|---|
| `AEController`, `AEAnncController` | 4 each | **yes** |
| `FlexContainerController`, `FlexContainerAnncController` | 4 each | **yes** |
| `MgmtObjController`, `MgmtObjAnncController` | 4 each | **yes** |
| `NodeController` | 2 | partially |
| `DiscoveryController` | 1 | yes |
| **`ContainerController`** | **0** — uses plain `checkACP` | **no** |
| `ContentInstanceController` | 0 | no |
| `GroupController`, `SubscriptionController` | 0 | no |

`ContainerController` calls `checkACP(...)` directly at all four operations, so a
`<container>` request never enters the DAC code path at all. Corroboration: OM2M's own DAS
test suite contains `DASServiceTest_Ae` and `DASServiceTest_FlexContainer` but **no**
`DASServiceTest_Container`.

**Consequence:** `sui-protected-cnt` is a `<container>` and **cannot** be the DAC-protected
resource — not even via the parent walk, because the walk is only reached from
`checkPermissions`, which `ContainerController` never calls. The DAC-protected resource must
be an `<AE>`, `<flexContainer>`, `<mgmtObj>` or `<node>`. **This implementation uses an `<AE>`**
(`sui-dac-ae`): `AEController.doRetrieve` calls `checkPermissions` unconditionally, and AEs are
already provisioned successfully over plain HTTP by this project.

### 3.2 `daci` is only persisted by *some* controllers

`ContainerController` and `CSEBaseController` ignore `dynamicAuthorizationConsultationIDs`
entirely — only AE, AEAnnc, DAC, FlexContainer(+Annc), MgmtObj(+Annc), NodeAnnc and RemoteCSE
call `ControllerUtil.buildDacEntityList(...)`. So setting `daci` on a container, or on the
CSEBase, is accepted-and-dropped: the attribute exists on the resource class but nothing
stores it. Attaching the DAC to the **AE** is therefore the only route that both persists the
link and reaches the hook. `AEController` lines ~231-234:

```java
// dynamicAuthorizationConsultationIDs O
if (!ae.getDynamicAuthorizationConsultationIDs().isEmpty()) {
    aeEntity.setDynamicAuthorizationConsultations(
            ControllerUtil.buildDacEntityList(ae.getDynamicAuthorizationConsultationIDs(), transaction));
}
```

### 3.3 The granted privilege must echo the requested operation **exactly**

`DynamicAuthorizationSelector.checkACPs` validates the DAS's response with **`equals()`, not a
bitwise AND**:

```java
if (rule.getAccessControlOperations().equals(operation)) {
    for (String originatorRule : rule.getAccessControlOriginators()) {
        if (originator.matches(originatorRule.replace("*", ".*"))) return;
    }
}
```

A DAS that returned a permissive `acop=63` would be **rejected** for a RETRIEVE (`op=2`).
`SuiDasService` already does the right thing — `acr.setAccessControlOperations(operation)`,
echoing the requested operation — matching OM2M's own reference DAS. No change was needed,
but the constraint is now documented in the class javadoc so it is not "simplified" later.

### 3.4 `dap` must be the DAS AE's `ri`, and the protected resource's `ri` must be stable

`Redirector.retargetNotify` resolves the PoA with `getAeDAO().find(dbt, request.getTo())` —
keyed by **resourceID**. So `dynamicAuthorizationPoA` must be the `sui-das` AE's `ri`, not its
hierarchical path. (OM2M's own test does exactly this: `createDAS(getDasAE().getResourceID())`.)

Conversely, `DynamicAuthorizationSelector` sends the DAS
`targetedResourceID = resourceEntity.getResourceID()` — the **non-hierarchical** id. The HTTP
NOTIFY used by `proofs/*.sh` hand-writes a *hierarchical* uri instead. The on-chain policy key
and the `sui.mappings.properties` CapToken key must match whichever form actually arrives.

OM2M normally mints a random id (`/in-cse/CAE<random>`) per boot, which would force a new Sui
transaction after every restart. But `AEController` has a usable property:

```java
if (request.getFrom().startsWith("C")) assignAeiC = false;
...
aeEntity.setAeid(assignAeiC ? "C" + ShortName.AE.toUpperCase() + generatedId
                            : request.getFrom());
aeEntity.setResourceID("/" + Constants.CSE_ID + "/" + aeEntity.getAeid());
```

Creating the AE with originator **`Csui-dac-ae`** pins its id to **`/in-cse/Csui-dac-ae`**,
stable across reboots and provisionable on-chain once. (A "C"-prefixed originator also skips
the create-time permission check, so the CREATE succeeds against the restrictive ACP.) This is
why `bench/provision_das.sh` deliberately does *not* create that AE as `admin:admin`.

---

## 4. What changed

### `plugin/.../das/SuiDasService.java` — minimal, no behavioural change to existing paths
- Added one log line that **distinguishes the two routes**, which is what makes the
  verification decisive: `"Sui DAC consult"` when `request.getContent()` is a typed
  `SecurityInfo` (only reachable in-JVM via `DynamicAuthorizationSelector` → `Redirector` →
  `IpeSelector`), versus `"Sui NOTIFY consult"` for an external HTTP NOTIFY, which always
  arrives as a JSON `String`. The two can never be confused in the log.
- Recorded the four constraints above in the class javadoc.
- The existing HTTP NOTIFY path is **untouched** — `proofs/03,04,05,08_*.sh` and
  `bench/bench_access_latency.sh` keep working unchanged.

An earlier draft translated the non-hierarchical id to a hierarchical uri via
`DBUtilManager.getResourceByIdUtil()`. **That was removed**: that accessor exists only in
1.5.0/`master`, not in 1.3.0–1.4.1, so it would have broken the build on the release most
likely installed on the Pi. The deterministic-`ri` approach of §3.4 achieves the same result
with no OM2M API dependency and no new OSGi package import.

### `bench/provision_das.sh` — new "Part B" (steps 7-11), appended; steps 1-6 byte-identical
Creates, discovers ids as it goes (the in-memory DB regenerates them each boot):
- `acp_sui_dac` — restrictive ACP, `pv`/`pvs` grant `acop=63` to `admin:admin` and `/in-cse`
  **only**; the probe originator appears nowhere, so its static check fails by construction.
- `sui-dac` — `<dynamicAuthorizationConsultation>` (`ty=34`) with `dae:true` and
  `dap:[<sui-das AE ri>]`, discovered fresh each run.
- `sui-dac-ae` — `<AE>` with `acpi:[acp_sui_dac]` and `daci:[<sui-dac ri>]`, created as
  originator `Csui-dac-ae` so its `ri` is the stable `/in-cse/Csui-dac-ae`; then asserts both
  that the `ri` is as expected and that `daci` actually persisted.
- A probe plus log grep, with the interpretation printed inline.

### `scripts/bootstrap_testbed.sh`
Adds the on-chain half: `policy::set_policy` and a `cap_token::mint` for
`DAC_RES="/in-cse/Csui-dac-ae"` (note the **non-hierarchical** form, per §3.4), and prints the
exact `sui.mappings.properties` lines needed.

### New files
- `scripts/verify_c2_dac.sh` — the decisive test (§5).
- `scripts/compile_plugin_offline.sh` — type-checks `plugin/` against real OM2M sources.

### Not touched
`install_das_persistence.sh` is the *other* reboot-recovery path and also provisions the
permissive `acp_admin`; it is outside this change's ownership. **It does not yet create the
DAC resources** — use `bench/provision_das.sh` for the C2 path, or port Part B into it.

### Build-infrastructure finding (independent of C2)
`plugin/pom.xml` declares `org.eclipse.om2m:*:1.1.0` with **no `<repositories>` block**, and
those artifacts are **not on Maven Central**. The local repository contains only empty
markers — `org.eclipse.om2m.commons-1.1.0.jar.lastUpdated` with `.error=` (a 404) and no
`.jar`. Every other dependency resolves fine. So `mvn package` cannot currently build this
plugin from a clean checkout; the Pi must be building against locally installed OM2M jars.

**Verification performed here:** `plugin/` type-checks cleanly (`javac`, no errors) against
real OM2M sources at **both `1.4.1` and `1.5.0`** via
`scripts/compile_plugin_offline.sh`. That validates the API usage across the plausible
installed releases. It is a compile check, not a runtime test.

---

## 5. Decisive verification on the Pi

Run `./scripts/verify_c2_dac.sh [node_ip]` after `bench/provision_das.sh` and the on-chain
provisioning. It runs four probes designed so the outcome cannot be ambiguous.

Minimal manual equivalent — the one probe that decides it:

```bash
# ordinary RETRIEVE: no X-M2M-Operation header, no hand-crafted SecurityInfo body
curl -i 'http://127.0.0.1:8282/~/in-cse/in-name/sui-dac-ae' \
     -H 'X-M2M-Origin: Csensor-001' \
     -H 'X-M2M-RI: c2probe' \
     -H 'Accept: application/json'

docker logs --since 20s om2m-active 2>&1 \
  | grep -iE 'Sui DAC consult|Sending notification to IPE|Sui GRANT|Sui DENY|No Sui mapping'
```

**The grep that settles it is the literal string `Sui DAC consult`.**

| Outcome | Meaning |
|---|---|
| `Sui DAC consult: originator=Csensor-001 resource=/in-cse/Csui-dac-ae op=2` **+ HTTP 200** + `Sui GRANT` | **C2 confirmed, strongest form** — an ordinary request was authorized on-chain. |
| `Sui DAC consult` **+ HTTP 403** + `Sui DENY` | **C2 confirmed** — the hook fired; the chain denied. Fix the on-chain policy / CapToken / `sui.mappings.properties` for `/in-cse/Csui-dac-ae`, then re-run. |
| `Sui DAC consult` + `No Sui mapping for originator=…` | Hook fired; the originator→address / token mapping is missing. Still confirms C2. |
| **HTTP 403 and no Sui or IPE line at all** | **C2 refuted on this build** — see below. |

Controls (should hold either way, and falsify a documented assumption if they don't):

```bash
# 2. admin IS in acp_sui_dac -> static grant short-circuits the DAC.
#    Expect HTTP 200 and NO Sui line (proves consultation is gated on static failure, §1).
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:8282/~/in-cse/in-name/sui-dac-ae' \
     -H 'X-M2M-Origin: admin:admin'

# 3. a <container> must NOT reach the DAS (§3.1).
#    Expect HTTP 403 and NO Sui line. A Sui line here falsifies §3.1.
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:8282/~/in-cse/in-name/sui-protected-cnt' \
     -H 'X-M2M-Origin: Csensor-001'

# 4. regression guard: the legacy synthetic path proofs/*.sh depend on must still work.
#    Expect HTTP 200 and a "Sui NOTIFY consult" + GRANT/DENY line.
curl -s -o /dev/null -w '%{http_code}\n' -X POST 'http://127.0.0.1:8282/~/in-cse/in-name/sui-das' \
     -H 'X-M2M-Origin: admin:admin' -H 'X-M2M-Operation: 5' -H 'Content-Type: application/json' \
     -d '{"m2m:sec":{"sit":1,"dreq":{"or":"admin:admin","op":1,"rid":"/in-cse/in-name/sui-protected-cnt","rty":3}}}'
```

### If the probe fails

Diagnose in this order — each step distinguishes a different root cause:

1. **`GET /~/in-cse/in-name/sui-dac` returns 404** → this build rejected `ty=34`. The
   installed OM2M predates the DAC implementation (i.e. it is a 1.0.0-era build, whatever its
   label). C2 is genuinely impossible on it; upgrade to a 1.3.0+ build.
2. **`sui-dac` exists but `sui-dac-ae`'s `daci` is empty** → `AEController` did not persist the
   link. Check that `daci` was sent as a JSON **array** and that the DAC `ri` was correct.
3. **`daci` is populated but no log line** → the hook is not firing. Confirm the static ACP
   really denies (control 2 must return 200 while the probe returns 403), and that
   `dae` is `true`.
4. **`Sending notification to IPE` is absent but a DAC attempt is logged** → `dap` does not
   resolve to the `sui-das` AE's `ri`, or the AE's `poa` no longer matches
   `SuiDasService.getAPOCPath()` (`sui.das.apoc.path`, default `sui-das`). Note `retargetNotify`
   also requires the `sui-das` AE to have `rr:true` and an ACP granting NOTIFY to
   `admin:admin` — `acp_admin` provides this, so **keep `acp_admin` on `sui-das`** and apply
   the restrictive ACP only to `sui-dac-ae`.

Only if step 1 is the failure is C2 unachievable. In that case — and **only** then — the paper
must fall back to the honest claim in §6.3.

---

## 6. What the paper must say

### 6.1 Claims that are now supportable (once `verify_c2_dac.sh` passes)
- The DAS integrates through oneM2M's **standard** dynamic-authorization extension point
  (`<dynamicAuthorizationConsultation>`, TS-0001 / TS-0003 clause 7.3, resource type 34),
  with **no modification to OM2M core** — core exports no packages, and none were needed.
- An **ordinary** oneM2M request (no special headers, no hand-crafted payload) that static
  ACPs do not grant is routed by the Hosting CSE itself to the Sui DAS, whose on-chain
  decision determines whether access is granted.

### 6.2 Claims that must be stated precisely, not overclaimed
- **Not "transparent interception".** Dynamic authorization is a **fallback consulted only
  when the static ACP check fails** (TS-0001; `Controller.checkPermissions`). It can only
  *grant* access, never revoke it. The architecture is "static ACPs grant nothing, so every
  decision falls through to the chain" — say that, because it is both true and stronger.
  Claiming the DAS *mediates* or *intercepts* all requests is false: a permissive ACP
  silently bypasses the chain entirely, which is exactly the bug this work fixed.
- **Resource-type scope.** On OM2M, DAS protection covers `<AE>`, `<flexContainer>`,
  `<mgmtObj>` and `<node>` — **not `<container>` or `<contentInstance>`** (§3.1). Do not
  illustrate the mechanism with a container. If the paper needs sensor *data* under DAS
  control, model it as a `<flexContainer>`, not `<container>`/`<contentInstance>`.
- **Version.** Cite the OM2M release (e.g. "Eclipse OM2M 1.4.x") rather than the Maven
  artifact version `1.1.0`, which is an internal, frozen bundle version and does **not**
  correspond to any OM2M release. Saying "OM2M 1.1.0" is wrong — no such release exists.

### 6.3 Honest fallback, if and only if step 1 of §5 fails
Then the installed OM2M lacks resource type 34, and the only working route is the
`InterworkingService` NOTIFY. The paper would have to say: the DAS is reached by a oneM2M
NOTIFY delivered to its AE point of access, and the reported measurements characterise the
**decision engine** (identity, trust, capability, policy, audit, all on-chain) rather than
transparent enforcement by the CSE. It must **not** claim ordinary requests are intercepted.

### 6.4 What the existing proof scripts do and do not demonstrate
This matters because the evidence base rests on them.

**They do demonstrate** — genuinely, and this is not diminished by anything above — that
given a `DYNAMIC_AUTHORIZATION_REQUEST`, the Sui DAS executes the atomic 6-step PTB and
returns a conformant `DynAuthDasResponse`: capability-token validation
(`proofs/03`), PTB atomicity (`04`), on-chain policy enforcement (`05`), audit trail (`08`),
plus latency in `bench/`. The `SecurityInfo`/`DynAuthDasResponse` structures they exercise are
the same ones the CSE uses, and the downstream code path is shared with the DAC route.

**They do not demonstrate** that OM2M consults the DAS. Every one of
`proofs/03,04,05,08_*.sh`, `bench/bench_access_latency.sh`, `bench/bench_latency_clean.sh`
and `bench/bench_latency_v2.sh` POSTs a hand-written `{"m2m:sec":{"sit":1,"dreq":{…}}}` body
with `X-M2M-Operation: 5` **directly at the DAS's own AE path** `/~/in-cse/in-name/sui-das`.
That is the DAS answering a question put to it directly by the test harness, not the CSE
asking it. Separately, the ACP that actually protected `sui-protected-cnt` granted
`acop=63` statically, so an ordinary CREATE/RETRIEVE there was allowed outright and **never
consulted the DAS** — and because `sui-protected-cnt` is a `<container>`, it could not have
done so even with a DAC attached (§3.1).

Those scripts should therefore be described as **decision-engine / DAS-conformance
measurements**, with the new `sui-dac-ae` probe cited as the separate evidence that the CSE
performs the consultation. Reported latencies from the NOTIFY path measure the DAS decision
itself; the DAC route adds OM2M's own ACP evaluation and in-JVM dispatch, which is in-process
and small but **has not been measured here**. If the paper quotes end-to-end request latency
under DAS control, re-measure on the `sui-dac-ae` path rather than reusing the NOTIFY numbers.
