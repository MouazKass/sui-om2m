#!/usr/bin/env bash
# 04_cutover.sh - ROLLOUT_V8.md phase F: move all three Pis from v7 to v8.
#
# Run from Git Bash on the laptop (it holds the node SSH key). The two steps
# that need the publisher key (create_cluster, config generation) are run
# inside WSL automatically.
#
#   04_cutover.sh prepare    no downtime: upload bundle, back up v7 config,
#                            snapshot each live container as :rpiN-v7-final
#                            (the rollback point), build the :rpiN-v8 image
#   04_cutover.sh cluster    create the v8 failover cluster (bootstrap step 14).
#                            Its 20 min lease starts now, so run it right
#                            before 'config' and 'switch'
#   04_cutover.sh config     generate per-node config from deployment.env
#                            and upload it
#   04_cutover.sh switch     DOWNTIME: recreate brokers and CSE containers on
#                            v8 with durable mounts and log rotation, install
#                            v8 host provisioning, re-provision DAS + DAC
#   04_cutover.sh verify     read-only health and v8 behaviour checks
#   04_cutover.sh redeploy   v8 -> v8 update (new bundle, config or mesh):
#                            run 'prepare' (and 'config' if changed) first.
#                            Recreates both containers from the same
#                            definitions 'switch' uses; durable state is kept
#   04_cutover.sh rollback   back to the v7 containers, config and scripts
#   04_cutover.sh cleanup    after verify passes: remove the v7 containers
#                            (frees rpi1's 2.6 GB unrotated log). Ends the
#                            rollback window, though :rpiN-v7-final images stay.
#
# What "durable" means here. Every v7 container read its config through host
# /tmp, which only survived reboots because Raspberry Pi OS currently keeps
# /tmp on disk (Debian trixie makes it tmpfs). v8 binds straight from
# ~/sui-runtime-config. Logs are rotated (json-file max-size/max-file).
set -euo pipefail

CMD="${1:-}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="$HOME/.ssh/id_ed25519_suiom2m"
NODES=(1 2 3)
declare -A IP=([1]=10.25.96.200 [2]=10.25.96.201 [3]=10.25.96.203)
IMG=mouazkass/om2m-sui-in
RT=/home/user/sui-runtime-config
STAMP=20261110
PRODUCT=/root/git/org.eclipse.om2m/org.eclipse.om2m.site.mn-cse/target/products/mn-cse/linux/gtk/aarch64
CONF=$PRODUCT/configuration
JAR_IN=$PRODUCT/plugins/org.eclipse.om2m.sui-0.1.0-SNAPSHOT.jar
JAR_LOCAL="$REPO/plugin/target/org.eclipse.om2m.sui-0.1.0-SNAPSHOT.jar"

ssh_n() { ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "user@${IP[$1]}" "${@:2}"; }
scp_n() { scp -q -i "$KEY" -o BatchMode=yes "$2" "user@${IP[$1]}:$3"; }
wsl_run() { printf '%s\n' "$1" | wsl.exe -d Ubuntu -- bash -s 2>&1 | tr -d '\r'; }
say() { echo; echo "=== $* ==="; }

# Remote environment shared by all node-side snippets.
remote_env() {
  cat <<EOF
set -euo pipefail
N=$1; IMG=$IMG; RT=$RT; STAMP=$STAMP
PRODUCT=$PRODUCT; CONF=$CONF; JAR_IN=$JAR_IN
EOF
}

prepare() {
  [ -f "$JAR_LOCAL" ] || { echo "FATAL: no bundle at $JAR_LOCAL - run scripts/build_bundle.sh in WSL"; exit 1; }
  local sha; sha=$(sha256sum "$JAR_LOCAL" | cut -d' ' -f1)
  echo "bundle sha256: $sha"
  for n in "${NODES[@]}"; do
    say "prepare rpi$n (${IP[$n]})"
    ssh_n "$n" "mkdir -p $RT/v8 $RT/state $RT/mosquitto/data"
    scp_n "$n" "$JAR_LOCAL" "$RT/v8/sui.jar"
    scp_n "$n" "$REPO/deploy/v8/host/provision-das.sh" "$RT/v8/provision-das.sh"
    scp_n "$n" "$REPO/deploy/v8/host/das-watchdog.sh" "$RT/v8/das-watchdog.sh"
    # Loop-free mesh config (per-origin out-only bridges; see gen-mesh-conf.sh).
    local self_addr; self_addr=$(sed 's/\r$//' "$REPO/scripts/env.sh" | sed -n "s/^export RPI$n=//p")
    [ -n "$self_addr" ] || { echo "FATAL: RPI$n missing from scripts/env.sh"; exit 1; }
    local peers=(); for m in "${NODES[@]}"; do [ "$m" = "$n" ] || peers+=("${IP[$m]}"); done
    local mesh; mesh=$(mktemp)
    bash "$REPO/deploy/mosquitto/gen-mesh-conf.sh" "${IP[$n]}" "$self_addr" "${peers[0]}" "${peers[1]}" > "$mesh"
    scp_n "$n" "$mesh" "$RT/v8/mosquitto-mesh.conf"; rm -f "$mesh"
    { remote_env "$n"; cat <<'EOF'
got=$(sha256sum "$RT/v8/sui.jar" | cut -d' ' -f1)
[ "$got" = "$WANT" ] || { echo "FATAL: uploaded bundle sha256 $got != $WANT"; exit 1; }
echo "bundle upload verified"

# v7 config backup (once)
if [ ! -d "$RT/v7-backup-$STAMP" ]; then
  mkdir -p "$RT/v7-backup-$STAMP"
  cp "$RT/sui.properties" "$RT/sui.mappings.properties" "$RT/v7-backup-$STAMP/"
  sudo cp /usr/local/bin/provision-das.sh "$RT/v7-backup-$STAMP/provision-das.sh"
  sudo cp /usr/local/bin/das-watchdog.sh  "$RT/v7-backup-$STAMP/das-watchdog.sh"
  echo "v7 config + host scripts backed up to $RT/v7-backup-$STAMP"
fi

# FM4: cseType must already be in-cse in the live container (the fix lives
# only in its writable layer, which is why the snapshot is taken from it).
# Read it from the v7 snapshot when it exists: that is what the v8 image is
# built from, and it works even when the node's container is stopped.
if docker image inspect "$IMG:rpi$N-v7-final" >/dev/null 2>&1; then
  ct=$(docker run --rm --entrypoint sh "$IMG:rpi$N-v7-final" -c "grep -E '^org.eclipse.om2m.cseType=' $CONF/config.ini" || true)
else
  ct=$(docker exec om2m-active sh -c "grep -E '^org.eclipse.om2m.cseType=' $CONF/config.ini" || true)
fi
[ "$ct" = "org.eclipse.om2m.cseType=in-cse" ] || { echo "FATAL: config.ini has '$ct' (FM4)"; exit 1; }

# Rollback point: snapshot of the live v7 container (once).
if ! docker image inspect "$IMG:rpi$N-v7-final" >/dev/null 2>&1; then
  docker commit om2m-active "$IMG:rpi$N-v7-final" >/dev/null
  echo "snapshot: $IMG:rpi$N-v7-final"
fi

# v8 image = v7 snapshot + new bundle + cleared Equinox cache. Built in a
# throwaway container; the running one is never touched.
docker rm -f om2m-v8-prep >/dev/null 2>&1 || true
docker create --name om2m-v8-prep --entrypoint sh "$IMG:rpi$N-v7-final" -c "rm -rf $CONF/org.eclipse.osgi" >/dev/null
docker start -a om2m-v8-prep
docker cp "$RT/v8/sui.jar" "om2m-v8-prep:$JAR_IN"
docker commit \
  --change 'ENTRYPOINT ["/root/start_scripts/start_arm64.sh"]' \
  --change 'CMD ["8282","in-cse","9090"]' \
  om2m-v8-prep "$IMG:rpi$N-v8" >/dev/null
docker rm om2m-v8-prep >/dev/null
inimg=$(docker run --rm --entrypoint sha256sum "$IMG:rpi$N-v8" "$JAR_IN" | cut -d' ' -f1)
[ "$inimg" = "$WANT" ] || { echo "FATAL: bundle in image $inimg != $WANT"; exit 1; }
docker run --rm --entrypoint sh "$IMG:rpi$N-v8" -c "[ ! -d $CONF/org.eclipse.osgi ]" \
  || { echo "FATAL: Equinox cache still present in v8 image"; exit 1; }
echo "image $IMG:rpi$N-v8 built: bundle verified, Equinox cache cleared"

# Durable broker config is the generated loop-free mesh; keep the old one once.
[ -f "$RT/v7-backup-$STAMP/mosquitto-mesh.conf" ] || cp /tmp/mosquitto-mesh.conf "$RT/v7-backup-$STAMP/mosquitto-mesh.conf"
grep -q " out 0" "$RT/v8/mosquitto-mesh.conf" || { echo "FATAL: generated mesh config looks wrong"; exit 1; }
sudo chown 1883:1883 "$RT/mosquitto/data"
echo "prepare done"
EOF
    } | sed "1a WANT=$sha" | ssh_n "$n" bash -s
  done
}

cluster() {
  say "create the v8 failover cluster (bootstrap step 14; lease starts now)"
  wsl_run "cd /mnt/c/Users/Mouaz/Desktop/files/sui-om2m && bash scripts/v8/02_bootstrap.sh --execute" \
    | grep -E "^\[14\]|OK:|FATAL|FAIL|SKIP" | head
  grep -q '^export CLUSTER=' "$REPO/deploy/v8/deployment.env" || { echo "FATAL: CLUSTER not recorded"; exit 1; }
}

config() {
  say "generate per-node config from deployment.env"
  wsl_run "cd /mnt/c/Users/Mouaz/Desktop/files/sui-om2m && bash scripts/v8/03_gen_config.sh" | tail -8
  for n in "${NODES[@]}"; do
    local d="$REPO/deploy/v8/nodes/rpi$n"
    [ -f "$d/sui.properties" ] || { echo "FATAL: $d/sui.properties missing"; exit 1; }
    scp_n "$n" "$d/sui.properties" "$RT/v8/sui.properties"
    scp_n "$n" "$d/sui.mappings.properties" "$RT/v8/sui.mappings.properties"
    echo "rpi$n: config uploaded"
  done
}

deploy_node() {
  { remote_env "$1"; echo "MODE=$2"; cat <<'EOF'
for f in sui.jar sui.properties sui.mappings.properties provision-das.sh das-watchdog.sh mosquitto-mesh.conf; do
  [ -f "$RT/v8/$f" ] || { echo "FATAL: $RT/v8/$f missing (run prepare + config)"; exit 1; }
done
docker image inspect "$IMG:rpi$N-v8" >/dev/null || { echo "FATAL: no v8 image"; exit 1; }

# Retire the current containers: switch keeps the v7 ones for rollback,
# redeploy just replaces the v8 ones.
if [ "$MODE" = switch ]; then
  docker stop mosquitto om2m-active >/dev/null
  docker rename mosquitto mosquitto-v7-old && docker update --restart no mosquitto-v7-old >/dev/null
  docker rename om2m-active om2m-v7-old && docker update --restart no om2m-v7-old >/dev/null
else
  docker rm -f mosquitto om2m-active >/dev/null
fi

# Durable sources of truth (v7 copies are in v7-backup-*).
cp "$RT/v8/mosquitto-mesh.conf" "$RT/mosquitto/mosquitto-mesh.conf"
cp "$RT/v8/sui.properties" "$RT/sui.properties"
cp "$RT/v8/sui.mappings.properties" "$RT/sui.mappings.properties"
cp "$RT/sui.properties" /tmp/sui.properties
cp "$RT/sui.mappings.properties" /tmp/sui.mappings.properties
[ -e /tmp/current-parent-poa ] || touch /tmp/current-parent-poa

# --- THE container definitions (the only place they live) ---
# Broker first, so the mesh is up when the CSE starts gossiping.
docker run -d --name mosquitto --restart unless-stopped --network host \
  --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
  -v "$RT/mosquitto/mosquitto-mesh.conf:/mosquitto/config/mosquitto.conf:ro" \
  -v "$RT/mosquitto/data:/mosquitto/data" \
  eclipse-mosquitto:2 /usr/sbin/mosquitto -c /mosquitto/config/mosquitto.conf >/dev/null
echo "broker started (loop-free mesh, durable config, rotated logs)"

docker run -d --name om2m-active --restart unless-stopped \
  --log-driver json-file --log-opt max-size=50m --log-opt max-file=5 \
  -p 8282:8282 -p 8080:8282 \
  -v /home/user/.sui/sui_config:/root/.sui/sui_config:rw \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$RT/sui.properties:$CONF/sui.properties" \
  -v "$RT/sui.mappings.properties:$CONF/sui.mappings.properties" \
  -v /tmp/current-parent-poa:/tmp/current-parent-poa \
  -v "$RT/state:/var/lib/sui-om2m" \
  "$IMG:rpi$N-v8" >/dev/null
echo "CSE started on $IMG:rpi$N-v8"

sudo install -m 755 "$RT/v8/provision-das.sh" /usr/local/bin/provision-das.sh
sudo install -m 755 "$RT/v8/das-watchdog.sh"  /usr/local/bin/das-watchdog.sh
echo "v8 host provisioning installed"
EOF
  } | ssh_n "$1" bash -s
}

provision_node() {
  ssh_n "$1" 'for i in $(seq 1 60); do c=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8282/~/in-cse -H "X-M2M-Origin: admin:admin"); [ "$c" = "200" ] && break; sleep 5; done; echo "CSE: HTTP $c"; /usr/local/bin/provision-das.sh'
}

switch() {
  for n in "${NODES[@]}"; do say "switch rpi$n"; deploy_node "$n" switch; done
  for n in "${NODES[@]}"; do say "provision rpi$n"; provision_node "$n"; done
}

redeploy() {
  for n in "${NODES[@]}"; do say "redeploy rpi$n"; deploy_node "$n" redeploy; done
  for n in "${NODES[@]}"; do say "provision rpi$n"; provision_node "$n"; done
}

verify() {
  for n in "${NODES[@]}"; do
    say "verify rpi$n"
    ssh_n "$n" 'docker ps --format "{{.Names}} {{.Image}} {{.Status}}" | grep -E "om2m-active|mosquitto" | grep -v old
      echo "CSE: $(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8282/~/in-cse -H "X-M2M-Origin: admin:admin")"
      echo "restart policy: $(docker inspect om2m-active --format "{{.HostConfig.RestartPolicy.Name}}"), log: $(docker inspect om2m-active --format "{{json .HostConfig.LogConfig.Config}}")"
      docker logs --since 15m om2m-active 2>&1 | grep -iE "NativePtbBuilder ready|Lease anchored|PoA published|Lease anchor failed|B6 observer epoch|Exception|ERROR" | tail -6
      for r in sui-das sui-dac-ae; do echo "$r: $(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8282/~/in-cse/in-name/$r -H "X-M2M-Origin: admin:admin")"; done'
  done
  say "gossip wire format on the mesh (expect v2)"
  ssh_n 3 'timeout 15 docker exec mosquitto mosquitto_sub -h 127.0.0.1 -t "om2m/trust/obs/#" 2>/dev/null | cut -c1-40 | sort | uniq -c | head'
  say "C2: ordinary RETRIEVE on the DAC-protected AE as Csensor-001 (mapped on rpi3)"
  ssh_n 3 'curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:8282/~/in-cse/in-name/sui-dac-ae -H "X-M2M-Origin: Csensor-001" -H "Accept: application/json"; sleep 6; docker logs --since 30s om2m-active 2>&1 | grep -iE "Sui (GRANT|DENY)|No Sui mapping|DAC consult" | tail -4'
}

rollback() {
  for n in "${NODES[@]}"; do
    say "rollback rpi$n"
    { remote_env "$n"; cat <<'EOF'
docker inspect om2m-v7-old >/dev/null 2>&1 || { echo "no om2m-v7-old on this node - nothing to roll back"; exit 0; }
docker rm -f om2m-active mosquitto >/dev/null 2>&1 || true
docker rename om2m-v7-old om2m-active && docker update --restart unless-stopped om2m-active >/dev/null
docker rename mosquitto-v7-old mosquitto && docker update --restart unless-stopped mosquitto >/dev/null
cp "$RT/v7-backup-$STAMP/sui.properties" "$RT/v7-backup-$STAMP/sui.mappings.properties" "$RT/"
cp "$RT/sui.properties" /tmp/sui.properties; cp "$RT/sui.mappings.properties" /tmp/sui.mappings.properties
sudo install -m 755 "$RT/v7-backup-$STAMP/provision-das.sh" /usr/local/bin/provision-das.sh
sudo install -m 755 "$RT/v7-backup-$STAMP/das-watchdog.sh"  /usr/local/bin/das-watchdog.sh
docker start mosquitto om2m-active >/dev/null
echo "rolled back to v7"
EOF
    } | ssh_n "$n" bash -s
  done
}

cleanup() {
  for n in "${NODES[@]}"; do
    say "cleanup rpi$n"
    ssh_n "$n" 'docker rm om2m-v7-old mosquitto-v7-old 2>/dev/null; echo "v7 containers removed; rollback images kept:"; docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "v7-final|v8"'
  done
}

case "$CMD" in
  prepare|cluster|config|switch|redeploy|verify|rollback|cleanup) "$CMD" ;;
  *) sed -n '2,25p' "$0"; exit 1 ;;
esac
