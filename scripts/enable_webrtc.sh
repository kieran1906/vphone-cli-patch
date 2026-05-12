#!/bin/zsh
# enable_webrtc.sh — Re-enable WebRTC in Safari on a vphone VM.
#
# Reverses disable_webrtc.sh by removing the managed WebKit prefs plist.
# Called on boot when --webrtc-disable is not passed.
#
# Usage (from Mac):
#   ./scripts/enable_webrtc.sh vm3

set -euo pipefail

VM_DIR="${1:?Usage: enable_webrtc.sh <VM_DIR>}"

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
rm -f "/var/Managed Preferences/mobile/com.apple.WebKit.plist" 2>/dev/null || true

killall Safari 2>/dev/null || true
killall mobilesafarid 2>/dev/null || true

echo "[+] WebRTC re-enabled (managed prefs plist removed)"
echo "[+] Safari killed — will pick up new prefs on next launch"
' 2>&1

echo "[webrtc] Done"
