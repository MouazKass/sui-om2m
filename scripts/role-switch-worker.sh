#!/bin/sh
ROLE="$1"
POA="$2"
echo "=== $(date) worker start ==="

case "$ROLE" in
  in)
    NEW_IMAGE="mouazkass/om2m-sui-in:rpi1"
    ENV_ARGS=""
    ;;
  mn)
    NEW_IMAGE="mouazkass/om2m-sui-mn:rpi1"
    ENV_ARGS="-e CURRENT_PARENT_POA=$POA"
    ;;
esac

# Idempotency check
CURRENT_IMAGE=$(docker inspect om2m-active --format '{{.Config.Image}}' 2>/dev/null || echo "")
echo "[worker] current=$CURRENT_IMAGE target=$NEW_IMAGE"
if [ "$CURRENT_IMAGE" = "$NEW_IMAGE" ]; then
  echo "[worker] already on target, exit"
  exit 0
fi

# Launch a courier container that does the swap from OUTSIDE this container.
# The courier outlives us because it's started by the docker daemon directly.
COURIER_CMD="set -x; sleep 5; docker rm -f om2m-active; sleep 8; docker run -d --name om2m-active -p 8282:8282 -p 8080:8282 -v /tmp/sui.properties:/root/git/org.eclipse.om2m/org.eclipse.om2m.site.mn-cse/target/products/mn-cse/linux/gtk/aarch64/configuration/sui.properties -v /tmp/sui.mappings.properties:/root/git/org.eclipse.om2m/org.eclipse.om2m.site.mn-cse/target/products/mn-cse/linux/gtk/aarch64/configuration/sui.mappings.properties -v /tmp/current-parent-poa:/tmp/current-parent-poa -v /home/user/.sui/sui_config:/root/.sui/sui_config:ro -v /var/run/docker.sock:/var/run/docker.sock $ENV_ARGS $NEW_IMAGE; sleep 2"

echo "[worker] launching courier"
docker run -d --rm \
  --name role-switch-courier \
  -v /var/run/docker.sock:/var/run/docker.sock \
  docker:cli sh -c "$COURIER_CMD"

echo "[worker] courier launched, returning"
