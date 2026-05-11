#!/bin/zsh
# disable_webrtc.sh — Disable WebRTC in Safari on a vphone VM.
#
# Prevents STUN/TURN IP leaks by disabling RTCPeerConnection entirely.
# The device will report "WebRTC not supported" — normal for managed devices.
#
# Usage (from Mac):
#   ./scripts/disable_webrtc.sh vm3

set -euo pipefail

VM_DIR="${1:?Usage: disable_webrtc.sh <VM_DIR>}"

vm_num="${VM_DIR//[^0-9]/}"
vm_num="${vm_num:-1}"
SSH_PORT=$(( 2230 + vm_num ))

SSH_CMD=(sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o ConnectTimeout=10 root@127.0.0.1 -p "$SSH_PORT")

echo "[webrtc] VM: $VM_DIR  SSH: $SSH_PORT"

if ! "${SSH_CMD[@]}" "echo ok" 2>/dev/null | grep -q ok; then
    echo "[-] SSH not available on port $SSH_PORT"
    exit 1
fi

"${SSH_CMD[@]}" "
# Disable WebRTC peer connection in all WebKit contexts
defaults write com.apple.Safari WebKitPreferences.peerConnectionEnabled -bool false
defaults write com.apple.WebKit WebKitPreferences.peerConnectionEnabled -bool false

# Also set via nsud for good measure (covers mobile Safari)
nsud set bool '/var/mobile/Library/Preferences/com.apple.Safari' WebKitPreferences.peerConnectionEnabled false 2>/dev/null || true
nsud set bool '/var/mobile/Library/Preferences/com.apple.WebKit' WebKitPreferences.peerConnectionEnabled false 2>/dev/null || true

# Kill Safari so it picks up the new preferences on next launch
killall Safari 2>/dev/null || true
killall mobilesafarid 2>/dev/null || true

echo '[+] WebRTC disabled (peerConnectionEnabled = false)'
echo '[+] Safari killed — will pick up new prefs on next launch'
" 2>&1

echo "[webrtc] Done"
