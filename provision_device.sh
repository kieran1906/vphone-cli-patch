#!/bin/bash
# provision_device.sh — Fully automated new device provisioning.
#
# Usage:
#   ./provision_device.sh                        # auto-names next vmN
#   ./provision_device.sh vm4                    # specific name
#   VPHONE_SUDO_PASSWORD=xxx ./provision_device.sh
#
# Runs the full pipeline:
#   vm_new → fw_prepare → fw_patch_jb → restore → ramdisk → cfw_install_jb → boot
#
# After completion, SSH is available:
#   ssh root@127.0.0.1 -p <assigned_port>   password: alpine

set -euo pipefail
cd "$(dirname "$0")"

# ── Colours ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[provision]${NC} $*"; }
warn() { echo -e "${YELLOW}[provision]${NC} $*"; }
die()  { echo -e "${RED}[provision] FATAL:${NC} $*"; exit 1; }

# ── Sudo password ─────────────────────────────────────────────
VPHONE_SUDO_PASSWORD="${VPHONE_SUDO_PASSWORD:-}"
if [[ -z "$VPHONE_SUDO_PASSWORD" ]]; then
    read -s -p "Mac sudo password (for ramdisk mount): " VPHONE_SUDO_PASSWORD
    echo
fi
export VPHONE_SUDO_PASSWORD

# ── VM name ───────────────────────────────────────────────────
if [[ -n "${1:-}" ]]; then
    VM_DIR="$1"
else
    # Auto-pick next vmN that doesn't exist
    n=2
    while [[ -d "vm$n" ]]; do (( n++ )); done
    VM_DIR="vm$n"
fi
log "Provisioning new device: $VM_DIR"

# ── SSH port assignment (base 2230, increment per VM number) ──
vm_num="${VM_DIR//[^0-9]/}"
vm_num="${vm_num:-1}"
SSH_PORT=$(( 2230 + vm_num ))
log "SSH will be available on port $SSH_PORT after provisioning"

# ── Helpers ───────────────────────────────────────────────────
LIMD="./.limd/bin"
IRECOVERY="$LIMD/irecovery"
IDEVICE_ID="$LIMD/idevice_id"
IPROXY="$LIMD/iproxy"

wait_for_dfu() {
    log "Waiting for DFU device..."
    for i in $(seq 1 60); do
        if "$IRECOVERY" -q 2>/dev/null | grep -q "CPID"; then return 0; fi
        sleep 2
    done
    die "DFU device did not appear after 120s"
}

wait_for_ramdisk() {
    log "Waiting for ramdisk SSH (port 2222)..."
    for i in $(seq 1 60); do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=2 -o BatchMode=yes \
               -p 2222 root@127.0.0.1 true 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    die "Ramdisk SSH did not become available"
}

wait_for_device() {
    local udid="$1"
    log "Waiting for device $udid to appear..."
    for i in $(seq 1 90); do
        if "$IDEVICE_ID" -l 2>/dev/null | grep -q "$udid"; then return 0; fi
        sleep 2
    done
    die "Device $udid did not appear after 180s"
}

wait_for_ssh() {
    local port="$1"
    log "Waiting for SSH on port $port (setup script running — allow 5-10 min)..."
    for i in $(seq 1 120); do
        result=$(sshpass -p alpine ssh -p "$port" root@127.0.0.1 \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=3 'echo ok' 2>&1)
        if echo "$result" | grep -q '^ok$'; then
            return 0
        fi
        sleep 5
    done
    die "SSH on port $port did not become available after 10 min"
}

kill_dfu() {
    pkill -f "vphone-cli.*--dfu.*$VM_DIR\|$VM_DIR.*vphone-cli.*--dfu" 2>/dev/null || true
    pkill -f "vphone-cli.*--dfu" 2>/dev/null || true
    sleep 2
}

# ── Step 1: Create VM ─────────────────────────────────────────
log "=== [1/6] Creating VM ==="
if [[ ! -d "$VM_DIR" ]]; then
    make VM_DIR="$VM_DIR" vm_new CPU=4 MEMORY=2048 DISK_SIZE=64
else
    warn "VM_DIR $VM_DIR already exists, skipping vm_new"
fi

# ── Step 2: Prepare firmware ──────────────────────────────────
log "=== [2/6] Preparing firmware (uses cache if available) ==="
make VM_DIR="$VM_DIR" fw_prepare

# ── Step 3: Patch firmware ────────────────────────────────────
log "=== [3/6] Patching firmware ==="
make VM_DIR="$VM_DIR" fw_patch_jb

# ── Step 4: Restore ───────────────────────────────────────────
log "=== [4/6] Restoring device ==="
kill_dfu
make VM_DIR="$VM_DIR" boot_dfu &
DFU_PID=$!
wait_for_dfu

make VM_DIR="$VM_DIR" restore_get_shsh
make VM_DIR="$VM_DIR" restore
log "Restore complete — device will kernel panic (expected)"
kill_dfu
sleep 5

# ── Step 5: Ramdisk ───────────────────────────────────────────
log "=== [5/6] Sending ramdisk ==="
make VM_DIR="$VM_DIR" boot_dfu &
DFU_PID=$!
wait_for_dfu

make VM_DIR="$VM_DIR" ramdisk_build
make VM_DIR="$VM_DIR" ramdisk_send

# Ramdisk is now booted — device appears as SSHRD_Script
log "Waiting for ramdisk device to appear..."
SSHRD_UDID=""
for i in $(seq 1 30); do
    SSHRD_UDID=$("$IDEVICE_ID" -l 2>/dev/null | grep "SSHRD_Script" || true)
    [[ -n "$SSHRD_UDID" ]] && break
    sleep 2
done
[[ -n "$SSHRD_UDID" ]] || die "Ramdisk device (SSHRD_Script) did not appear"
log "Ramdisk device: $SSHRD_UDID"

# Start iproxy targeting the ramdisk device specifically
pkill -f "iproxy.*2222 22" 2>/dev/null || true
sleep 1
"$IPROXY" -u "$SSHRD_UDID" 2222 22 &
IPROXY_RAMDISK_PID=$!
sleep 3

# ── Step 6: Install CFW + JB ──────────────────────────────────
log "=== [6/6] Installing CFW + JB ==="
make VM_DIR="$VM_DIR" cfw_install_jb
kill $IPROXY_RAMDISK_PID 2>/dev/null || true
kill_dfu
sleep 3

# ── Get predicted UDID ────────────────────────────────────────
UDID=$(cat "$VM_DIR/udid-prediction.txt" 2>/dev/null | grep '^UDID=' | cut -d= -f2)
[[ -n "$UDID" ]] || die "Could not read UDID from $VM_DIR/udid-prediction.txt"

# ── Done ──────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Provisioning complete!                                      ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  VM:   $VM_DIR$(printf '%*s' $((54 - ${#VM_DIR})) '')║${NC}"
echo -e "${GREEN}║  UDID: $UDID$(printf '%*s' $((54 - ${#UDID})) '')║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Next steps:                                                 ║${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║  1. Boot the device:                                         ║${NC}"
echo -e "${GREEN}║     make VM_DIR=$VM_DIR boot$(printf '%*s' $((47 - ${#VM_DIR})) '')║${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║  2. Go through the iOS setup wizard (skip everything)        ║${NC}"
echo -e "${GREEN}║     Do NOT select Japan or EU region                         ║${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║  3. Wait 5-10 min for on-device setup to complete, then SSH: ║${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║     Start tunnel:                                            ║${NC}"
echo -e "${GREEN}║     ./.limd/bin/iproxy -u $UDID $SSH_PORT 22$(printf '%*s' $((10 - ${#SSH_PORT})) '')║${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║     ssh mobile@127.0.0.1 -p $SSH_PORT$(printf '%*s' $((25 - ${#SSH_PORT})) '')║${NC}"
echo -e "${GREEN}║     ssh root@127.0.0.1   -p $SSH_PORT  (pass: alpine)$(printf '%*s' $((10 - ${#SSH_PORT})) '')║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
