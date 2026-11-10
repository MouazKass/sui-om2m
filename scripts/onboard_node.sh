#!/usr/bin/env bash
# onboard_node.sh - add a new Raspberry Pi to the testbed. Idempotent: every
# step checks first and skips what is already done, so re-run freely.
#
# Run from Git Bash on the laptop (it holds the node SSH key). The node must be
# listed in deploy/inventory.tsv (status=pending is fine). On-chain steps run in
# WSL as the publisher and do nothing without --execute.
#
#   scripts/onboard_node.sh <name> status            read-only: what is done, what is next
#   scripts/onboard_node.sh <name> preflight         SSH key auth, hostname/MAC vs inventory, OS/arch, sudo, disk, clock
#   scripts/onboard_node.sh <name> docker            install Docker CE like rpi1-3 (docker.com apt repo, suite = node codename, arm64)
#   scripts/onboard_node.sh <name> images            copy the OM2M base image + eclipse-mosquitto:2 from a donor node
#                                                    (DONOR=rpi2 to choose), tagged :<name>-base
#   scripts/onboard_node.sh <name> sui-key           install the sui CLI (same binary as the donor) and generate the
#                                                    node's ed25519 key ON THE PI; records its address (status=staged)
#   scripts/onboard_node.sh <name> onchain-register [--execute|--simulate]   identity::register   (publisher, WSL)
#   scripts/onboard_node.sh <name> onchain-trust    [--execute|--simulate]   trust::add_node      (publisher, WSL)
#   scripts/onboard_node.sh <name> onchain-cap      [--execute|--simulate]   trust::grant_admin_registered -> own cap;
#                                                    records TRUST_ADMIN_CAP_<NAME>, marks the node status=active
#   scripts/onboard_node.sh <name> config            generate every node's config (03_gen_config.sh) and upload this node's
#   scripts/onboard_node.sh <name> deploy            04_cutover.sh prepare + redeploy for this node only (builds :<name>-v8
#                                                    from :<name>-base), then the DAS provisioning
#   scripts/onboard_node.sh <name> host              host services: DAS provisioning unit + watchdog timer, gas watchdog
#   scripts/onboard_node.sh <name> fund              one gas-watchdog run now (faucet top-up if below 1 SUI)
#   scripts/onboard_node.sh <name> mesh              regenerate the broker mesh on EVERY active node (adds this node's
#                                                    bridges everywhere); restarts brokers only
#   scripts/onboard_node.sh <name> verify            04_cutover.sh verify for the node + it is seen by its peers
#
#   scripts/onboard_node.sh <name> offchain          preflight -> docker -> images -> sui-key, then prints the on-chain steps
#   scripts/onboard_node.sh <name> finish            config -> deploy -> host -> fund -> mesh -> verify (after onchain-cap)
#
# The node's private key is generated on the Pi and never leaves it; nothing
# here prints it or its recovery phrase (the phrase is discarded: the keystore
# file on the Pi is the only copy, as on rpi1-3).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/inventory.sh
. "$REPO/scripts/lib/inventory.sh"
inv_load

NAME="${1:-}"; STEP="${2:-status}"; FLAG="${3:-}"
[ -n "$NAME" ] || { sed -n '2,35p' "$0"; exit 1; }
inv_require "$NAME"
IP=${INV_IP[$NAME]}
KEY="$HOME/.ssh/id_ed25519_suiom2m"
IMG=mouazkass/om2m-sui-in
MOSQ=eclipse-mosquitto:2
RT=/home/user/sui-runtime-config
CUTOVER="$REPO/scripts/v8/04_cutover.sh"
MIN_FREE_GB=20

say() { echo; echo "=== $NAME: $* ==="; }
die() { echo "FATAL: $*" >&2; exit 1; }
ssh_to() { ssh -F "$INV_SSH_CONFIG" -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "user@$1" "${@:2}"; }
on() { ssh_to "$IP" "$@"; }
wsl_run() { printf '%s\n' "$1" | wsl.exe -d Ubuntu -- bash -s 2>&1 | tr -d '\r'; }
REPO_WSL=$(printf '%s' "$REPO" | sed -E 's#^/([a-zA-Z])/#/mnt/\L\1/#')

donor() {
  local d="${DONOR:-}"
  if [ -z "$d" ]; then
    for n in $(inv_nodes active); do [ "$n" != "$NAME" ] && [ "${INV_DAS[$n]}" = no ] && { d=$n; break; }; done
  fi
  [ -n "$d" ] && [ "${INV_STATUS[$d]:-}" = active ] || die "no active donor node (set DONOR=)"
  echo "$d"
}

# ------------------------------------------------------------------ steps
preflight() {
  say "preflight ($IP)"
  if ! on true 2>/dev/null; then
    cat >&2 <<EOF
FATAL: cannot SSH to user@$IP with key auth ($KEY).
  - Is the Pi powered, on the campus network / VPN, and answering ping?   ping $IP
  - Authorize the laptop key once (it asks for the Pi's password; type it yourself):
        ! ssh-copy-id -i $KEY.pub user@$IP
  Then re-run: scripts/onboard_node.sh $NAME preflight
EOF
    exit 1
  fi
  on 'set -e
    echo "hostname: $(hostname)"
    echo "user: $(id -un)"
    echo "mac: $(cat /sys/class/net/eth0/address 2>/dev/null || echo none)"
    . /etc/os-release; echo "os: $VERSION_CODENAME"
    echo "arch: $(uname -m)"
    echo "mem_gb: $(free -g | awk "/^Mem:/{print \$2}")"
    echo "free_gb: $(df -BG --output=avail / | tail -1 | tr -dc 0-9)"
    echo "sudo: $(sudo -n true 2>/dev/null && echo ok || echo NO)"
    echo "ntp: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
    echo "docker: $(docker --version 2>/dev/null || echo none)"' > /tmp/onboard_pf.$$ || die "preflight commands failed"
  cat /tmp/onboard_pf.$$
  v() { sed -n "s/^$1: //p" /tmp/onboard_pf.$$; }
  local bad=0
  [ "$(v hostname)" = "${INV_HOST[$NAME]}" ] || { echo "  MISMATCH hostname: inventory says ${INV_HOST[$NAME]}"; bad=1; }
  [ "$(v user)" = user ]                     || { echo "  MISMATCH: scripts assume login user 'user'"; bad=1; }
  [ "$(v mac)" = "${INV_MAC[$NAME]}" ]       || { echo "  MISMATCH eth0 MAC: inventory says ${INV_MAC[$NAME]} (wrong Pi at this IP?)"; bad=1; }
  [ "$(v arch)" = aarch64 ]                  || { echo "  arch must be aarch64 (the images are arm64)"; bad=1; }
  case "$(v os)" in trixie|bookworm) ;; *) echo "  OS must be Debian trixie (rpi1-3) or bookworm (rpi4/rpi5); docker suite follows the node"; bad=1;; esac
  [ "$(v sudo)" = ok ]                       || { echo "  passwordless sudo is required (as on rpi1-3)"; bad=1; }
  [ "$(v free_gb)" -ge $MIN_FREE_GB ]        || { echo "  need >= ${MIN_FREE_GB} GB free on / (images ~4 GB + logs)"; bad=1; }
  [ "$(v ntp)" = yes ]                       || echo "  WARN: clock not NTP-synchronised (trust clock-drift signal and leases depend on it)"
  rm -f /tmp/onboard_pf.$$
  [ $bad = 0 ] || die "preflight failed for $NAME"
  echo "preflight OK"
}

docker_step() {
  say "docker"
  if on 'docker --version >/dev/null 2>&1 && id -nG | tr " " "\n" | grep -qx docker && systemctl is-active --quiet docker'; then
    on 'docker --version'; echo "already installed - skipped"; return
  fi
  # Same source, suite and packages as rpi1-3 (read from rpi1 on 2026-11-10):
  #   deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable
  #   docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  on 'set -euo pipefail
    sudo install -m 0755 -d /etc/apt/keyrings
    [ -s /etc/apt/keyrings/docker.asc ] || sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -q
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
    sudo usermod -aG docker user
    sudo docker --version'
  # group membership applies to new sessions; check through a fresh one
  on 'docker ps >/dev/null && echo "docker usable by user"' || die "docker installed but not usable by 'user' yet (re-run the step)"
}

images() {
  local d; d=$(donor)
  say "images (donor $d ${INV_IP[$d]})"
  local src="$IMG:$d-v7-final" want_base want_mosq
  want_base=$(ssh_to "${INV_IP[$d]}" "docker image inspect --format '{{.Id}}' $src") || die "donor $d has no $src"
  want_mosq=$(ssh_to "${INV_IP[$d]}" "docker image inspect --format '{{.Id}}' $MOSQ") || die "donor $d has no $MOSQ"
  # The OM2M base: the donor's v7-final snapshot (cseType=in-cse already set,
  # FM4). 04_cutover.sh prepare builds :<name>-v8 from it with the current bundle.
  if [ "$(on "docker image inspect --format '{{.Id}}' $IMG:$NAME-base 2>/dev/null" || true)" = "$want_base" ]; then
    echo "$IMG:$NAME-base present ($want_base) - skipped"
  else
    echo "copying $src -> $NAME (~1.6 GB through the laptop)"
    ssh_to "${INV_IP[$d]}" "docker save $src" | on "docker load" | tail -1
    on "docker tag $src $IMG:$NAME-base && docker rmi $src >/dev/null"
    [ "$(on "docker image inspect --format '{{.Id}}' $IMG:$NAME-base")" = "$want_base" ] || die "image id mismatch after copy"
    echo "$IMG:$NAME-base loaded ($want_base)"
  fi
  if [ "$(on "docker image inspect --format '{{.Id}}' $MOSQ 2>/dev/null" || true)" = "$want_mosq" ]; then
    echo "$MOSQ present - skipped"
  else
    ssh_to "${INV_IP[$d]}" "docker save $MOSQ" | on "docker load" | tail -1
    [ "$(on "docker image inspect --format '{{.Id}}' $MOSQ")" = "$want_mosq" ] || die "$MOSQ id mismatch after copy"
  fi
}

sui_key() {
  local d; d=$(donor)
  say "sui-key"
  local want; want=$(ssh_to "${INV_IP[$d]}" "sha256sum /usr/local/bin/sui | cut -d' ' -f1")
  if [ "$(on "sha256sum /usr/local/bin/sui 2>/dev/null | cut -d' ' -f1" || true)" != "$want" ]; then
    ssh_to "${INV_IP[$d]}" "cat /usr/local/bin/sui" | on "sudo tee /usr/local/bin/sui >/dev/null && sudo chmod 755 /usr/local/bin/sui"
    [ "$(on "sha256sum /usr/local/bin/sui | cut -d' ' -f1")" = "$want" ] || die "sui CLI copy mismatch"
  fi
  # The donor binary (and the official ubuntu-aarch64 release) needs glibc >= 2.39:
  # fine on trixie (rpi1-3), too new for bookworm (rpi4/rpi5, glibc 2.36). There it
  # runs inside a throwaway debian:trixie-slim container ON THE PI (--network none,
  # the caller's uid, only ~/.sui mounted), so the key is still generated on the node.
  on 'mkdir -p "$HOME/.sui/sui_config"; /usr/local/bin/sui --version >/dev/null 2>&1 || docker image inspect debian:trixie-slim >/dev/null 2>&1 || docker pull -q debian:trixie-slim >/dev/null'
  on 'sui_run() { if /usr/local/bin/sui --version >/dev/null 2>&1; then /usr/local/bin/sui "$@"; else docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME="$HOME" -v "$HOME/.sui:$HOME/.sui" -v "${T:-/tmp}:${T:-/tmp}" -v /usr/local/bin/sui:/usr/local/bin/sui:ro debian:trixie-slim /usr/local/bin/sui "$@"; fi; }; sui_run --version'
  # Generate (or find) the node key ON the Pi. The container mounts
  # ~/.sui/sui_config at /root/.sui/sui_config, so client.yaml names the
  # container path - exactly the layout of rpi1-3. A temporary host-path
  # client.yaml is used to run the CLI here.
  local addr
  addr=$(on 'set -euo pipefail
    D=$HOME/.sui/sui_config; mkdir -p "$D"; chmod 775 "$D"
    T=$(mktemp -d); trap "rm -rf $T" EXIT
    sui_run() { if /usr/local/bin/sui --version >/dev/null 2>&1; then /usr/local/bin/sui "$@"; else docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME="$HOME" -v "$HOME/.sui:$HOME/.sui" -v "${T:-/tmp}:${T:-/tmp}" -v /usr/local/bin/sui:/usr/local/bin/sui:ro debian:trixie-slim /usr/local/bin/sui "$@"; fi; }
    [ -s "$D/sui.keystore" ] || { printf "[]\n" > "$D/sui.keystore"; chmod 600 "$D/sui.keystore"; }
    [ -s "$D/sui.aliases" ]  || printf "[]\n" > "$D/sui.aliases"
    [ -s "$D/external.keystore" ] || printf "{}" > "$D/external.keystore"   # a JSON object, as on rpi1-3 ([] breaks the CLI)
    [ -s "$D/external.aliases" ]  || printf "{}" > "$D/external.aliases"
    n=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$D/sui.keystore")
    printf -- "---\nkeystore:\n  File: %s/sui.keystore\nenvs:\n  - alias: testnet\n    rpc: \"https://fullnode.testnet.sui.io:443\"\n    ws: ~\n    basic_auth: ~\nactive_env: testnet\nactive_address: ~\n" "$D" > "$T/client.yaml"
    if [ "$n" = 0 ]; then
      # JSON includes the recovery phrase: parse out the address only, never print the rest.
      sui_run client --client.config "$T/client.yaml" new-address ed25519 --json 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin)[\"address\"])"
    elif [ "$n" = 1 ]; then
      sui_run client --client.config "$T/client.yaml" addresses --json 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); a=d.get(\"addresses\") or []; print(a[0][1] if a and isinstance(a[0], list) else d.get(\"activeAddress\") or \"\")"
    else
      echo "FATAL: $D/sui.keystore holds $n keys; a node must hold exactly one" >&2; exit 1
    fi')
  addr=${addr,,}
  [[ "$addr" =~ ^0x[0-9a-f]{64}$ ]] || die "could not determine the node address (got '$addr')"
  # Container-layout client.yaml (same shape as rpi1-3).
  on "cat > ~/.sui/sui_config/client.yaml <<'Y'
---
keystore:
  File: /root/.sui/sui_config/sui.keystore
external_keys:
  External: /root/.sui/sui_config/external.keystore
envs:
  - alias: testnet
    rpc: \"https://fullnode.testnet.sui.io:443\"
    ws: ~
    basic_auth: ~
active_env: testnet
active_address: \"$addr\"
Y"
  local cur=${INV_ADDR[$NAME]}
  if [ -n "$cur" ] && [ "$cur" != "$addr" ]; then
    die "inventory has $cur for $NAME but the Pi's key is $addr - resolve by hand (never overwrite an onboarded identity)"
  fi
  if [ -z "$cur" ]; then
    inv_set "$NAME" sui_address "$addr"
    inv_set "$NAME" status staged
    echo "recorded $NAME sui_address=$addr (status staged) in deploy/inventory.tsv"
  else
    echo "key present: $addr (inventory status ${INV_STATUS[$NAME]})"
  fi
}

onchain() {  # register|trust|cap
  say "onchain-$1"
  [ -n "${INV_ADDR[$NAME]}" ] || die "no address yet: run '$0 $NAME sui-key' first"
  wsl_run "cd '$REPO_WSL' && bash scripts/onboard_onchain.sh $1 $NAME $FLAG"
  inv_load
}

require_active() {
  [ "${INV_STATUS[$NAME]}" = active ] || die "$NAME is ${INV_STATUS[$NAME]}: finish onchain-register/-trust/-cap (with --execute) first"
}

config_step() {
  require_active
  say "config (all active nodes regenerated, $NAME uploaded)"
  on "mkdir -p $RT/v8 $RT/state $RT/mosquitto/data"
  ONLY="$NAME" bash "$CUTOVER" config
}

deploy_step() {
  require_active
  say "deploy (prepare + redeploy, $NAME only)"
  [ -f "$REPO/plugin/target/org.eclipse.om2m.sui-0.1.0-SNAPSHOT.jar" ] || die "no bundle: run scripts/build_bundle.sh in WSL"
  ONLY="$NAME" bash "$CUTOVER" prepare
  ONLY="$NAME" bash "$CUTOVER" redeploy
}

host_step() {
  require_active
  say "host services"
  local d="$RT/v8/host"
  on "mkdir -p $d"
  for f in provision-das.sh das-watchdog.sh sui-das-provision.service das-watchdog.service das-watchdog.timer \
           gas-watchdog.py install-gas-watchdog.sh sui-gas-watchdog.service sui-gas-watchdog.timer sui-gas-watchdog.default; do
    scp -q -F "$INV_SSH_CONFIG" -i "$KEY" -o BatchMode=yes "$REPO/deploy/v8/host/$f" "user@$IP:$d/$f"
  done
  on "set -euo pipefail
    sudo install -m 755 $d/provision-das.sh /usr/local/bin/provision-das.sh
    sudo install -m 755 $d/das-watchdog.sh  /usr/local/bin/das-watchdog.sh
    sudo install -m 644 $d/sui-das-provision.service $d/das-watchdog.service $d/das-watchdog.timer /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable sui-das-provision.service >/dev/null
    sudo systemctl enable --now das-watchdog.timer >/dev/null
    echo 'DAS provisioning unit + watchdog timer installed'
    sudo bash $d/install-gas-watchdog.sh | tail -3"
}

fund_step() {
  require_active
  say "fund (gas watchdog, one run)"
  on 'sudo /usr/local/bin/sui-gas-watchdog; sudo /usr/local/bin/sui-gas-watchdog --status | tail -5'
}

verify_step() {
  require_active
  say "verify"
  ONLY="$NAME" bash "$CUTOVER" verify
  local das; das=$(inv_das)
  echo; echo "--- is $NAME seen by its peers? (gossip + heartbeat topics on $das's broker, 20 s)"
  ssh_to "${INV_IP[$das]}" "timeout 20 docker exec mosquitto mosquitto_sub -h 127.0.0.1 -v -t 'om2m/trust/obs/+/${INV_ADDR[$NAME]}' -t 'om2m/failover/heartbeat/+/${INV_ADDR[$NAME]}' 2>/dev/null | cut -d' ' -f1 | sort | uniq -c" \
    || echo "  (nothing received)"
  wsl_run "cd '$REPO_WSL' && bash scripts/onboard_onchain.sh status $NAME"
}

status_step() {
  say "status (inventory: ${INV_STATUS[$NAME]}, ip $IP, address ${INV_ADDR[$NAME]:-none})"
  if ! on true 2>/dev/null; then
    echo "  SSH: not reachable with key auth -> next: power/network, then '! ssh-copy-id -i $KEY.pub user@$IP', then preflight"
    return 0
  fi
  on "echo \"  docker: \$(docker --version 2>/dev/null || echo none)\"
      for t in base v8; do echo \"  image :$NAME-\$t: \$(docker image inspect $IMG:$NAME-\$t >/dev/null 2>&1 && echo present || echo none)\"; done
      echo \"  key: \$([ -s ~/.sui/sui_config/sui.keystore ] && python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))),\"key(s)\")' ~/.sui/sui_config/sui.keystore || echo none)\"
      echo \"  containers: \$(docker ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')\"
      echo \"  timers: \$(systemctl is-enabled das-watchdog.timer sui-gas-watchdog.timer 2>/dev/null | tr '\n' ' ')\"" || true
  local capv; capv=$(inv_cap_var "$NAME")
  grep -q "^export $capv=" "$REPO/deploy/v8/deployment.env" && echo "  $capv recorded" || echo "  $capv not recorded (onchain-cap)"
}

case "$STEP" in
  status)    status_step ;;
  preflight) preflight ;;
  docker)    docker_step ;;
  images)    images ;;
  sui-key)   sui_key ;;
  onchain-register) onchain register ;;
  onchain-trust)    onchain trust ;;
  onchain-cap)      onchain cap ;;
  config)    config_step ;;
  deploy)    deploy_step ;;
  host)      host_step ;;
  fund)      fund_step ;;
  mesh)      require_active; bash "$CUTOVER" mesh ;;
  verify)    verify_step ;;
  offchain)
    preflight; docker_step; images; sui_key
    cat <<EOF

=== $NAME: off-chain part done. On-chain admission (publisher, WSL; each prints the tx first):
  scripts/onboard_node.sh $NAME onchain-register --execute
  scripts/onboard_node.sh $NAME onchain-trust    --execute
  scripts/onboard_node.sh $NAME onchain-cap      --execute
then:
  scripts/onboard_node.sh $NAME finish
EOF
    ;;
  finish)
    config_step; deploy_step; host_step; fund_step
    say "mesh (every active node)"; bash "$CUTOVER" mesh
    verify_step ;;
  *) die "unknown step '$STEP' (see: $0)" ;;
esac
