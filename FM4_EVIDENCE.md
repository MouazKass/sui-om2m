# FM4: Crash/Restart Reconciles to Chain Truth + No Registration Loop — FIXED & VERIFIED

Status: VERIFIED on the live testnet cluster, 2026-06-24.
Closes invariant FM4. Supersedes the earlier "needs image rebuild" finding.

## Two parts to FM4
1. Role reconciliation on restart (Sui layer) — was already correct.
2. The 5103 upstream-registration loop (OM2M layer) — now ROOT-CAUSED and FIXED.

## Real root cause of the 5103 loop (NOT an image/build problem)
OM2M's CSEInitializer.init() guards upward registration on CSE type:
    if (!Constants.CSE_TYPE.equalsIgnoreCase(CSEType.IN) && CSE_AUTHENTICATION) {
        registerCSE(); // ... loops every 10s on failure
    }
An IN-CSE is meant to SKIP this (it has no registrar). But:
  - Constants.CSE_TYPE = System.getProperty("org.eclipse.om2m.cseType", ...)
  - CSEType.IN is the String "in-cse"  (NOT "IN")
Our config.ini had  org.eclipse.om2m.cseType=IN .
  "IN".equalsIgnoreCase("in-cse")  ==  false
  => !false  ==  true  => the node thought it was NOT an IN-CSE and registered
     upward to 127.0.0.1:8080 (REMOTE_CSE defaults), looping 5103 forever.
This is why blanking the remoteCse* config block never helped (the trigger is
the CSE-type comparison, and the target falls back to defaults); and why it
looked "compiled in" (the message is built dynamically in CSEInitializer).

## The fix (one config value, faithful to oneM2M IN-CSE semantics)
config.ini:  org.eclipse.om2m.cseType=IN  ->  org.eclipse.om2m.cseType=in-cse
Now "in-cse".equalsIgnoreCase("in-cse") == true => the registration block is
skipped entirely. The node is a true IN-CSE (top of hierarchy, no registrar).
Confirmed at the data level: cseBase now reports cst=1 (IN_CSE).

## Durability
config.ini is baked in the image (NOT host-mounted; only sui.properties is).
The live fix survives docker restart but would revert on docker rm. Therefore a
per-node fixed image was committed (each keeps its node-specific cseBaseAddress):
  mouazkass/om2m-sui-in:rpi1-incse / rpi2-incse / rpi3-incse
RECOVERY.md updated: on container recreation, use the -incse image OR re-apply
cseType=in-cse.

## Live verification (all three nodes)
After fix: in-cse=200, 5103 count=0 on rpi1, rpi2, rpi3.

## FM4 invariant test (restart former parent after takeover)
1. parent=rpi1 (0xef9c6271...), epoch 42.
2. Stopped rpi1 -> rpi3 (0x27dacda1...) claimed parent, epoch 43.
3. Restarted rpi1. Result:
   - Chain parent STAYED rpi3 @ epoch 43 (rpi1 did NOT reclaim from stale belief).
   - rpi1 log: "Cluster current parent = 0x27dacda1..." then "Failover manager
     started. parent=0x27dacda1... self=0xef9c6271..." -> reconciled to FOLLOWER
     role from chain truth.
   - in-cse=200, 5103 count=0 on the fresh restart (loop gone through restart).
FM4 holds: restart reconciles to chain truth, correct role, no registration loop.
