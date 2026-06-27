#!/bin/bash
# file name: arm64.sh

set -e

if [ "$SSH_ENABLED" = "true" ]; then
    service ssh start
    if [ -n "$SSH_ROOT_PASSWORD" ]; then
        echo "root:$SSH_ROOT_PASSWORD" | chpasswd
    fi
fi

# Go to the ARM64 OM2M directory
cd /root/git/org.eclipse.om2m/org.eclipse.om2m.site.mn-cse/target/products/mn-cse/linux/gtk/aarch64

# --- Self-sufficiency fallback: restore baked v6 sui config if no valid mount ---
if [ -f /root/baked-sui.properties ]; then
  if [ ! -s configuration/sui.properties ] || grep -q "0xcba39e8bc98f6a7a40dc67aef7f150294b8a88fc5c72026fd8ed421b94419360" configuration/sui.properties 2>/dev/null; then
    echo "[startup] restoring baked v6 sui config (no current/valid mount detected)"
    cp /root/baked-sui.properties configuration/sui.properties
    [ -f /root/baked-sui.mappings.properties ] && cp /root/baked-sui.mappings.properties configuration/sui.mappings.properties
  else
    echo "[startup] mounted sui.properties present and current"
  fi
fi
# --- end fallback ---

# By default, registration is mandatory for ARM64
if [ "$SKIP_ARM64_REGISTRATION" != "true" ]; then
    echo "Running registration script (ARM64 mandatory by default)..."
    # Run the registration script in the background
    /root/registration.sh "$1" "$2" "$3" &
else
    echo "Skipping registration for ARM64..."
fi

# --- Launch mn-sync.py before starting the main server
if [ "$SKIP_MN_SYNC" != "true" ]; then
    echo "Launching mn-sync.py..."
    python3 /root/mn-sync.py &
    echo "Waiting 10 seconds to allow mn-sync.py to initialize..."
    sleep 10
else
    echo "SKIP_MN_SYNC=true => not launching mn-sync.py"
fi

# Start the main MN-CSE server
echo "Starting MN-CSE server..."
chmod +x start.sh
./start.sh &

# Wait on all background processes to keep the container alive
wait
