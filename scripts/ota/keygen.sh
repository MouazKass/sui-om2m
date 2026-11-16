#!/usr/bin/env bash
# keygen.sh - create the firmware-signing key, IN WSL on the publisher machine.
# Run from Git Bash or WSL. The private key stays in WSL (~/.sui-om2m-fw, 0700/0600);
# only the public key comes back, into deploy/v9/fw_keys/<label>.pub.
#   scripts/ota/keygen.sh [label]        (default label: release-1)
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
LABEL=${1:-release-1}
[[ $LABEL =~ ^[a-z0-9-]{1,32}$ ]] || { echo "bad label"; exit 1; }
SCRIPT='set -euo pipefail
d=$HOME/.sui-om2m-fw; k=$d/fw_signing.pem
umask 077; mkdir -p "$d"; chmod 700 "$d"
if [ -e "$k" ]; then echo "exists: $k (kept)" >&2; else openssl genpkey -algorithm ed25519 -out "$k"; chmod 600 "$k"; echo "created $k" >&2; fi
openssl pkey -in "$k" -pubout -outform DER | tail -c 32 | od -An -tx1 | tr -d " \n"'
if command -v wsl.exe >/dev/null 2>&1; then
  pub=$(printf '%s\n' "$SCRIPT" | wsl.exe -d Ubuntu -- bash -s | tr -d '\r')
else
  pub=$(bash -c "$SCRIPT")
fi
[[ $pub =~ ^[0-9a-f]{64}$ ]] || { echo "keygen failed: '$pub'"; exit 1; }
echo "$pub" > "$REPO/deploy/v9/fw_keys/$LABEL.pub"
echo "public key $pub -> deploy/v9/fw_keys/$LABEL.pub"
"$REPO/esp32/firmware/gen_fw_keys.sh"
