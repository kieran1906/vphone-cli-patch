#!/bin/zsh
# trust_pair.sh — Pre-seed a lockdownd pairing record so the Trust dialog
#                 never shows for a vphone VM.
#
# Usage:
#   ./scripts/trust_pair.sh <SSH_PORT>
#
# Examples:
#   ./scripts/trust_pair.sh 2232   # vm2
#   ./scripts/trust_pair.sh 2233   # vm3
#
# Behaviour:
#   - If the device already has the vphone HostID on record: just installs the
#     Mac-side lockdown entry (stamped with the new UDID). No dialog at all.
#   - If the device doesn't have the record: copies it over SSH, same result.
#   - Falls back to auto-tap if idevicepair still fails for any reason.
#
# One-time setup: run once on any VM. The pairing assets in ~/.vphone/pairing/
# are reused for every future clone — no Trust dialog ever.

set -euo pipefail
cd "${0:a:h}/.."

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[trust]${NC} $*"; }
warn() { echo -e "${YELLOW}[trust]${NC} $*"; }
die()  { echo -e "${RED}[trust] FATAL:${NC} $*"; exit 1; }

SSH_PORT="${1:?Usage: ./scripts/trust_pair.sh <SSH_PORT>}"
SSH_HOST="127.0.0.1"
SSH_PASS="alpine"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o IdentitiesOnly=yes)
LIMD="$(pwd)/.limd/bin"
PAIRING_DIR="$HOME/.vphone/pairing"

[[ -x "$LIMD/idevicepair" ]] || die ".limd/bin/idevicepair not found"
[[ -x "$LIMD/idevice_id"  ]] || die ".limd/bin/idevice_id not found"
command -v sshpass >/dev/null || die "sshpass not found"

ssh_cmd() { sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "root@$SSH_HOST" "$@"; }

# ── Get device UDID ────────────────────────────────────────────────────────────
log "Detecting UDID..."
UDID="$("$LIMD/idevice_id" -l 2>/dev/null | head -1)"
[[ -n "$UDID" ]] || die "No device found via usbmuxd — is the VM running?"
log "UDID: $UDID"

# ── Already paired? ────────────────────────────────────────────────────────────
if "$LIMD/idevicepair" -u "$UDID" validate >/dev/null 2>&1; then
    log "Already paired — nothing to do."
    exit 0
fi

# ── Check for saved pairing assets ────────────────────────────────────────────
if [[ ! -f "$PAIRING_DIR/device_pair_record.plist" || ! -f "$PAIRING_DIR/mac_pair_template.plist" ]]; then
    die "No pairing assets found in $PAIRING_DIR — run trust_pair.sh on a VM that already has a valid pair record first (or pair vm3 manually once)."
fi

HOST_ID="$(cat "$PAIRING_DIR/host_id")"

# ── Push device-side pair record ───────────────────────────────────────────────
log "Checking device-side pair record..."
if ! ssh_cmd "test -f /private/var/root/Library/Lockdown/pair_records/${HOST_ID}.plist" 2>/dev/null; then
    log "Copying pair record to device..."
    ssh_cmd "mkdir -p /private/var/root/Library/Lockdown/pair_records"
    sshpass -p "$SSH_PASS" scp "${SSH_OPTS[@]}" -P "$SSH_PORT" \
        "$PAIRING_DIR/device_pair_record.plist" \
        "root@$SSH_HOST:/private/var/root/Library/Lockdown/pair_records/${HOST_ID}.plist"
    ssh_cmd "killall lockdownd 2>/dev/null; true"
    sleep 2
else
    log "Device already has pair record for our HostID."
fi

# ── Install Mac-side record ────────────────────────────────────────────────────
log "Installing Mac-side record (needs sudo)..."
LOCKDOWN_FILE="/var/db/lockdown/${UDID}.plist"

# Stamp the new UDID into the template
python3 - <<PYEOF
import plistlib, shutil, sys
src = "$PAIRING_DIR/mac_pair_template.plist"
dst = "/tmp/vphone_pair_${UDID}.plist"
with open(src, "rb") as f:
    data = plistlib.load(f)
data["UDID"] = "$UDID"
with open(dst, "wb") as f:
    plistlib.dump(data, f)
PYEOF

echo "Run this to install the Mac-side record:"
echo "  sudo cp /tmp/vphone_pair_${UDID}.plist $LOCKDOWN_FILE && sudo chown _usbmuxd:_usbmuxd $LOCKDOWN_FILE && sudo chmod 600 $LOCKDOWN_FILE"

# If VPHONE_SUDO_PASSWORD is set, install non-interactively
if [[ -n "${VPHONE_SUDO_PASSWORD:-}" ]]; then
    echo "$VPHONE_SUDO_PASSWORD" | sudo -S cp "/tmp/vphone_pair_${UDID}.plist" "$LOCKDOWN_FILE"
    echo "$VPHONE_SUDO_PASSWORD" | sudo -S chown _usbmuxd:_usbmuxd "$LOCKDOWN_FILE"
    echo "$VPHONE_SUDO_PASSWORD" | sudo -S chmod 600 "$LOCKDOWN_FILE"
    log "Mac-side record installed."
else
    log "Set VPHONE_SUDO_PASSWORD env var to automate sudo, or run the command above."
    exit 0
fi

# ── Validate ───────────────────────────────────────────────────────────────────
log "Validating..."
sleep 1
if "$LIMD/idevicepair" -u "$UDID" validate 2>&1; then
    log "Paired — Trust dialog will never show for $UDID."
    exit 0
fi

# ── Fallback: auto-tap Trust ───────────────────────────────────────────────────
warn "Direct pair failed — falling back to auto-tap..."

vm_num="${SSH_PORT//[^0-9]/}"
vm_num="${vm_num: -1}"  # last digit

do_tap() {
    python3 "$(pwd)/device.py" --ssh-port "$SSH_PORT" tap "$1" "$2" 2>/dev/null || true
}

"$LIMD/idevicepair" -u "$UDID" pair 2>/dev/null || true
sleep 1
# Tap Trust (right button) across probable y range
for y in 530 550 570; do
    do_tap 295 "$y"
    sleep 0.3
done
sleep 1
"$LIMD/idevicepair" -u "$UDID" pair 2>&1 && log "Paired via auto-tap." || die "Pairing failed — check Trust dialog coordinates."
