#!/bin/zsh
# boot_proxy.sh — Boot a VM and auto-start iproxy once the device appears.
#
# Usage (called from Makefile):
#   zsh scripts/boot_proxy.sh <VM_DIR> <BUNDLE_BIN>
set -euo pipefail

VM_DIR="$1"
BUNDLE_BIN="$2"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIMD="$REPO_DIR/.limd/bin"
DEVICE_PY="$REPO_DIR/device.py"

# Derive SSH port from VM directory name (formula: 2230 + VM number)
vm_num="${VM_DIR//[^0-9]/}"
vm_num="${vm_num:-1}"
SSH_PORT=$(( 2230 + vm_num ))

echo "[boot] VM: $VM_DIR  SSH port: $SSH_PORT"

# Kill any existing processes on this SSH port
pkill -f "iproxy.*$SSH_PORT 22" 2>/dev/null || true
lsof -ti tcp:$SSH_PORT 2>/dev/null | xargs kill -9 2>/dev/null || true

# Background watcher: discover UDID dynamically, start iproxy, auto-trust
(
    echo "[boot] Waiting for device to appear..."

    # Snapshot UDIDs already present before this VM boots
    BEFORE=$("$LIMD/idevice_id" -l 2>/dev/null || true)

    # Wait for a new UDID to appear
    UDID=""
    for i in $(seq 1 120); do
        AFTER=$("$LIMD/idevice_id" -l 2>/dev/null || true)
        NEW=$(comm -13 <(echo "$BEFORE" | sort) <(echo "$AFTER" | sort) | grep -v '^$' | head -1 || true)
        if [[ -n "$NEW" ]]; then
            UDID="$NEW"
            break
        fi
        sleep 2
    done

    if [[ -z "$UDID" ]]; then
        echo "[boot] WARNING: no new device appeared — iproxy not started"
        exit 0
    fi

    echo "[boot] New device: $UDID"

    # Update udid-prediction.txt with new UDID
    CPID=$(echo "$UDID" | cut -d- -f1)
    ECID=$(echo "$UDID" | cut -d- -f2)
    printf 'UDID=%s\nCPID=0x%s\nECID=0x%s\nMACHINE_IDENTIFIER=config.plist\n' \
        "$UDID" "$CPID" "$ECID" > "$VM_DIR/udid-prediction.txt"
    echo "[boot] Updated udid-prediction.txt"

    # Start iproxy
    echo "[boot] Starting iproxy on port $SSH_PORT"
    "$LIMD/iproxy" -u "$UDID" "$SSH_PORT" 22 &
    IPROXY_PID=$!

    # Auto-tap Trust button (fixed coords, socket-based — no USB trust needed)
    # Trust dialog: "Trust" button is at approx (325, 555) in 430x932 space
    sleep 4
    python3 "$DEVICE_PY" --ssh-port "$SSH_PORT" tap 325 555 2>/dev/null && \
        echo "[boot] Auto-tapped Trust dialog" || true
) &

# Boot the VM (blocks until window is closed)
cd "$VM_DIR" && exec "$BUNDLE_BIN" --config ./config.plist
