#!/bin/zsh
# disable_webrtc.sh — Disable WebRTC in Safari on a vphone VM.
#
# Prevents STUN/TURN IP leaks by disabling RTCPeerConnection entirely.
# The device will report "WebRTC not supported" — normal for managed devices.
#
# Uses managed preferences (same mechanism as proxy config) — the only
# reliable write path on this iOS VM setup.
#
# Usage (from Mac):
#   ./scripts/disable_webrtc.sh vm3

set -euo pipefail

VM_DIR="${1:?Usage: disable_webrtc.sh <VM_DIR>}"

vm_num="${VM_DIR//[^0-9]/}"
vm_num="${vm_num:-1}"
SSH_PORT=$(( 2230 + vm_num ))

SSH_CMD=(sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o IdentitiesOnly=yes -o PreferredAuthentications=password -o ConnectTimeout=10 root@127.0.0.1 -p "$SSH_PORT")

echo "[webrtc] VM: $VM_DIR  SSH: $SSH_PORT"

if ! "${SSH_CMD[@]}" "echo ok" 2>/dev/null | grep -q ok; then
    echo "[-] SSH not available on port $SSH_PORT"
    exit 1
fi

"${SSH_CMD[@]}" '
MANAGED_DIR="/var/Managed Preferences/mobile"
mkdir -p "$MANAGED_DIR"

cat > "$MANAGED_DIR/com.apple.WebKit.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>WebKitPreferences.peerConnectionEnabled</key>
  <false/>
</dict>
</plist>
PLIST

killall Safari 2>/dev/null || true
killall mobilesafarid 2>/dev/null || true

echo "[+] WebRTC disabled via managed prefs"
echo "[+] Safari killed — will pick up new prefs on next launch"
' 2>&1

echo "[webrtc] Done"
