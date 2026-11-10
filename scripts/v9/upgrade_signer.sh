#!/usr/bin/env bash
# upgrade_signer.sh - the UpgradeCap multisig signers that live ON the Pis.
#
# Each node signer has a DEDICATED ed25519 "upgrade" key, separate from its node
# key (the node key signs plugin traffic all day; the upgrade key signs only a
# package upgrade, a few times a year). The key is generated on the Pi, stays in
# /home/user/.sui-upgrade/upgrade.keystore (dir 0700, file 0600), and is used
# only inside a throwaway container with NO network (`docker run --network none`,
# the node's own om2m-sui-in image for the sui CLI). Only the public key, the
# address and a signature ever leave the Pi.
#
# Run from Git Bash on the laptop:
#   upgrade_signer.sh init   <node>             create the key if absent; print "<address> <publicBase64Key>"
#   upgrade_signer.sh pubkey <node>             print "<address> <publicBase64Key>" of the existing key
#   upgrade_signer.sh show   <node> <tx.b64>    decode the tx ON the Pi (what the signer is about to sign)
#   upgrade_signer.sh sign   <node> <tx.b64>    sign the tx bytes on the Pi; print the suiSignature only
#
# There is no mnemonic backup on purpose: a lost or broken Pi is recovered by the
# other signers rotating the multisig (V9_SIGNERS.md section 5); a 12-word phrase
# on paper next to the Pi would only be a second copy to steal.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/inventory.sh
. "$REPO/scripts/lib/inventory.sh"
inv_load

die() { echo "FATAL: $*" >&2; exit 1; }
CMD="${1:-}"; N="${2:-}"
[ -n "$CMD" ] && [ -n "$N" ] || { sed -n '2,20p' "$0"; exit 1; }
inv_require "$N"
node_ssh() { ssh -F "$INV_SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=10 "${INV_IP[$N]}" "$@"; }
IMG="mouazkass/om2m-sui-in:$N-v8"

# Shared remote prologue: the offline sui runner. $SUIX <args> runs the CLI with
# the key dir mounted, as the login user (not root), with no network at all.
PRE='set -eu
D=$HOME/.sui-upgrade
SUIX="docker run --rm -i --network none --user $(id -u):$(id -g) -e HOME=/ks/home -v $D:/ks -w /ks --entrypoint /usr/local/bin/sui '"$IMG"'"
PYX="docker run --rm -i --network none --user $(id -u):$(id -g) -e HOME=/ks/home -v $D:/ks -w /ks --entrypoint python3 '"$IMG"'"
'

pubkey_remote='[ -s "$D/upgrade.keystore" ] || { echo "NOKEY"; exit 0; }
$SUIX keytool --keystore-path /ks/upgrade.keystore --json list | $PYX -c "
import json,sys
ks=json.load(sys.stdin)
if len(ks)!=1: sys.exit(\"FATAL: upgrade keystore must hold exactly one key, has %d\" % len(ks))
k=ks[0]; print(k[\"suiAddress\"], k[\"publicBase64Key\"])"'

case "$CMD" in
  init)
    out=$(node_ssh "$PRE"'
umask 077
mkdir -p "$D/tmp" "$D/home/.sui/sui_config"; chmod -R go-rwx "$D"
# keytool insists on a client.yaml; this one points only at the upgrade keystore
# (the container has no network, so the env is never contacted).
[ -s "$D/home/.sui/sui_config/client.yaml" ] || cat > "$D/home/.sui/sui_config/client.yaml" <<"Y"
---
keystore:
  File: /ks/upgrade.keystore
envs:
  - alias: testnet
    rpc: "https://fullnode.testnet.sui.io:443"
    ws: ~
    basic_auth: ~
active_env: testnet
active_address: ~
Y
if [ ! -s "$D/upgrade.keystore" ]; then
  # Generate inside the offline container; the mnemonic is read and imported
  # there and never printed. generate also drops <address>.key in /ks/tmp.
  $PYX - <<"PY"
import json,subprocess
g=subprocess.run(["sui","keytool","--json","generate","ed25519"],cwd="/ks/tmp",capture_output=True,text=True,check=True).stdout
j=json.loads(g)
subprocess.run(["sui","keytool","--keystore-path","/ks/upgrade.keystore","--json","import",j["mnemonic"],"ed25519"],
               capture_output=True,text=True,check=True)
PY
  find "$D/tmp" -type f -exec shred -u {} +
  chmod 600 "$D/upgrade.keystore"; [ -f "$D/upgrade.aliases" ] && chmod 600 "$D/upgrade.aliases"
  echo "CREATED" >&2
fi
'"$pubkey_remote")
    ;;
  pubkey)
    out=$(node_ssh "$PRE$pubkey_remote")
    ;;
  show|sign)
    F="${3:-}"; [ -s "$F" ] || die "usage: $0 $CMD <node> <tx.b64>"
    TX=$(tr -d '[:space:]' < "$F")
    [[ "$TX" =~ ^[A-Za-z0-9+/=]+$ ]] || die "$F is not Base64 tx bytes"
    if [ "$CMD" = show ]; then
      node_ssh "$PRE"'read -r TX; $SUIX keytool decode-or-verify-tx --tx-bytes "$TX"' <<<"$TX"
      exit 0
    fi
    out=$(node_ssh "$PRE$pubkey_remote"'
' 2>&1 | tail -1)
    [ "$out" != NOKEY ] || die "$N has no upgrade key; run: $0 init $N"
    addr=${out%% *}
    sig=$(node_ssh "$PRE"'read -r TX
$SUIX keytool --keystore-path /ks/upgrade.keystore --json sign --address '"$addr"' --data "$TX" | $PYX -c "import json,sys; print(json.load(sys.stdin)[\"suiSignature\"])"' <<<"$TX")
    [[ "$sig" =~ ^A[A-Za-z0-9+/=]{131}$ ]] || die "unexpected signature output from $N: ${sig:0:60}"
    echo "$sig"; exit 0
    ;;
  *) die "unknown command $CMD";;
esac

[ "$out" != NOKEY ] || die "$N has no upgrade key; run: $0 init $N"
read -r addr pk <<<"$out"
[[ "$addr" =~ ^0x[0-9a-f]{64}$ ]] && [[ "$pk" =~ ^A[A-Za-z0-9+/=]{43}$ ]] || die "unexpected output from $N: $out"
echo "$addr $pk"
