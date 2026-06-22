# FM4: OM2M 5103 Upstream Registration Loop — Root Cause (not yet fixed)

## Symptom
Every node logs, every 10s:
  Error in registration to another CSE. Retrying in 10s
  Target is not reachable: http://127.0.0.1:8080/~/in-cse  (5103)
OM2M serves normally throughout (in-cse returns 200, GRANT path works,
failover works). The loop is cosmetic noise but drowns FailoverManager logs.

## Root cause
The deployed product is org.eclipse.om2m.site.mn-cse (an MN-CSE build) run with
env CSE_TYPE=IN. An MN-CSE registers upward to a parent IN-CSE; this build still
attempts that registration to 127.0.0.1:8080 (nothing serves there; nodes listen
on 8282). The Sui-based failover replaced OM2M-native CSE hierarchy, so this
upward registration is vestigial.

## What was tried (2026-06-22) — none stopped the loop
config.ini lives at .../products/mn-cse/.../configuration/config.ini (baked in
the image, not host-mounted). Edits applied in-container + OSGi cache cleared +
restart:
  1. Blanked org.eclipse.om2m.remoteCseAddress  -> loop persisted (count ~6-12).
  2. Commented out the ENTIRE remote-CSE block (remoteCseId/Name/Port/Context/
     Address) -> loop still persisted (count 12).
Conclusion: the registration target is NOT driven by config.ini's remote-CSE
keys. It comes from elsewhere — likely the MN-CSE product startup script
(start_arm64.sh) or compiled CSE-type handling that reacts to ONEM2M_ID/CSE_TYPE,
or a hardcoded fallback. FM4 is therefore an IMAGE/BUILD-level fix, not a
config.ini change.

## Recommended fix (next session)
Build or obtain a genuine IN-CSE product (org.eclipse.om2m.site.in-cse) with no
remote-CSE / upward registration, and deploy that image — rather than the MN-CSE
product with CSE_TYPE=IN bolted on. Alternatively, inspect
/root/start_scripts/start_arm64.sh and the in-cse vs mn-cse product definitions
to find where the 127.0.0.1:8080 remote CSE is injected, and remove it at build
time. Verify after: in-cse 200, GRANT still produces a digest, 5103 count = 0.

## Note
Config edits are baked in the image: they survive `docker restart` but revert on
`docker rm`/`run`. Any live config experiment must account for this.
