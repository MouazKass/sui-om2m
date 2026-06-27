# Docker Images

## Current published images (Docker Hub, mouazkass/om2m-sui-in)
Pushed 2026-06-27 — capture the running cluster state after the v6 upgrade.

  :rpi1-v6   IN-CSE node rpi1 (10.25.96.200)  digest 992fcbe4...
  :rpi2-v6   MN-CSE node rpi2 (10.25.96.201)
  :rpi3-v6   MN-CSE node rpi3 (10.25.96.203)  digest f51ab3c2...  (demo/parent node)

Each image contains:
  - Plugin JAR md5 3e35597d... (native DAS path, AbortDecoder, SY5 isReplay,
    FM5 static isGasExhaustion — i.e. all fixes through 2026-06-27)
  - config.ini with org.eclipse.om2m.cseType=in-cse (the FM4 fix; the old
    published :rpi1 image still had the broken cseType=IN)
  - /root/baked-sui.properties + /root/baked-sui.mappings.properties — a backup
    copy of the v6 runtime config (package 0xb579914d..., sui.use.native.rpc=true)

## IMPORTANT — config mount dependency
The container startup reads sui.properties / sui.mappings.properties from a
BIND MOUNT (host /tmp/sui.properties -> container config path), NOT from the
baked copy. The baked /root/baked-* files are a recovery backup only.

So a container started from a :rpiN-v6 image still needs the host to provide
/tmp/sui.properties (v6 + native) at run time, or it will fall back to the
stale config baked at the real config path (which points at the ORIGINAL v1
package). To recover a node from the image alone:
    docker cp <container>:/root/baked-sui.properties /tmp/sui.properties
    docker cp <container>:/root/baked-sui.mappings.properties /tmp/sui.mappings.properties
    # then (re)start the container so the mount picks them up

## TODO (durability hardening — not yet done)
  - [DONE 2026-06-27] Startup script falls back to /root/baked-* when no valid
    mount is present (detects missing/stale-v1 config). Images :rpiN-v6 are now self-sufficient. Script saved in docker/start_scripts/start_arm64.sh.
  - Add a @reboot mechanism (cron or systemd) that restores /tmp/sui.properties
    from a durable location and starts the container with --restart=unless-stopped.
    Currently restart policy = "no" and /tmp config is volatile across reboots.

## The old :rpi1 tag is STALE — do not use
mouazkass/om2m-sui-in:rpi1 has cseType=IN (FM4 bug, 5103 loop), an old plugin
JAR (63690955...), and v1 package config. Superseded by the :rpiN-v6 tags above.

## UPDATE 2026-06-27 — reboot durability (set up, pending reboot test)
Applied to all 3 nodes:
  - ~/sui-runtime-config/{sui.properties,sui.mappings.properties} synced to the
    live v6 config (durable source of truth)
  - docker update --restart=unless-stopped om2m-active (auto-recover)
  - @reboot cron: restores /tmp config from ~/sui-runtime-config, starts the
    container (so volatile /tmp survives a reboot)
NOT YET reboot-tested. The startup-script fallback to /root/baked-* (full image
self-sufficiency) is still TODO.
