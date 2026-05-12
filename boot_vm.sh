#!/bin/zsh
# boot_vm.sh — Boot a vphone VM with optional proxy and frida tunnel.
#
# Usage:
#   ./boot_vm.sh <VM_DIR> [--proxy-mode socks5|http] [--proxy-line host:port:user:pass] [--webrtc-disable]
#
# Options:
#   --proxy-mode X    Proxy mode: "socks5" (default) or "http" (iproyal)
#   --proxy-line X    Full upstream proxy line: host:port:user:pass
#                     When provided, proxy forwarder is started and device proxy is configured.
#   --webrtc-disable  Disable WebRTC in Safari to prevent STUN IP leak
#
# Examples:
#   ./boot_vm.sh vm3
#   ./boot_vm.sh vm3 --proxy-mode socks5 --proxy-line 'gw-xxx:32330:user:pass'
#   ./boot_vm.sh vm3 --proxy-mode http --proxy-line 'geo.iproyal.com:12321:user:pass'
#   ./boot_vm.sh vm3 --webrtc-disable
#
# Ctrl+C cleanly stops the VM, proxy forwarder, and frida tunnel.

set -euo pipefail
cd "$(dirname "$0")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[boot]${NC} $*"; }
warn() { echo -e "${YELLOW}[boot]${NC} $*"; }
info() { echo -e "${BLUE}[boot]${NC} $*"; }
die()  { echo -e "${RED}[boot] FATAL:${NC} $*"; exit 1; }

VM_DIR="${1:?Usage: ./boot_vm.sh <VM_DIR> [--proxy-mode socks5|http] [--proxy-line host:port:user:pass] [--webrtc-disable] [--timezone TZ] [--clear-safari]}"
PROXY_MODE=""
PROXY_LINE=""
DISABLE_WEBRTC=0
TIMEZONE=""
CLEAR_SAFARI=0

shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --proxy-mode) PROXY_MODE="${2:?--proxy-mode requires socks5 or http}"; shift 2 ;;
        --proxy-line) PROXY_LINE="${2:?--proxy-line requires host:port:user:pass}"; shift 2 ;;
        --webrtc-disable) DISABLE_WEBRTC=1; shift ;;
        --timezone) TIMEZONE="${2:?--timezone requires a timezone e.g. America/New_York}"; shift 2 ;;
        --clear-safari) CLEAR_SAFARI=1; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Ports ─────────────────────────────────────────────────────────────────────
vm_num="${VM_DIR//[^0-9]/}"
vm_num="${vm_num:-1}"
SSH_PORT=$(( 2230 + vm_num ))
PROXY_PORT=$(( 12320 + vm_num ))
FRIDA_LOCAL_PORT=$(( 27040 + vm_num ))

# Proxy is active when --proxy-line is provided
PROXY_ACTIVE=0
if [[ -n "$PROXY_LINE" ]]; then
    PROXY_ACTIVE=1
    PROXY_MODE="${PROXY_MODE:-socks5}"
fi

# ── Background process tracking ───────────────────────────────────────────────
BOOT_PID=""
PROXY_PID=""
FRIDA_TUNNEL_PID=""

cleanup() {
    echo ""
    log "Shutting down $VM_DIR..."
    [[ -n "$FRIDA_TUNNEL_PID" ]] && kill "$FRIDA_TUNNEL_PID" 2>/dev/null && log "Frida tunnel stopped" || true
    [[ -n "$PROXY_PID" ]]        && kill "$PROXY_PID"        2>/dev/null && log "Proxy forwarder stopped" || true
    [[ -n "$BOOT_PID" ]]         && kill "$BOOT_PID"         2>/dev/null && log "VM stopped" || true
}
trap cleanup EXIT INT TERM

# ── SSH helpers ───────────────────────────────────────────────────────────────
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o ConnectTimeout=3 -o IdentitiesOnly=yes)

ssh_cmd() {
    sshpass -p alpine ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "root@127.0.0.1" "$@"
}

wait_for_ssh() {
    log "Waiting for SSH on port $SSH_PORT..."
    for i in $(seq 1 120); do
        if ssh_cmd 'echo ok' 2>/dev/null | grep -q '^ok$'; then
            return 0
        fi
        sleep 5
    done
    die "SSH on port $SSH_PORT did not become available after 10 min"
}

# ── Boot ──────────────────────────────────────────────────────────────────────
[[ -d "$VM_DIR" ]] || die "VM directory not found: $VM_DIR"

log "Booting $VM_DIR..."
make VM_DIR="$VM_DIR" boot > "/tmp/vphone_boot_${VM_DIR}.log" 2>&1 &
BOOT_PID=$!

# ── Proxy forwarder (Mac side, start early so it's ready by device boot) ──────
if [[ $PROXY_ACTIVE -eq 1 ]]; then
    log "Starting proxy forwarder ($PROXY_MODE) on port $PROXY_PORT..."
    zsh scripts/proxy_start.sh "$VM_DIR" --mode "$PROXY_MODE" --proxy-line "$PROXY_LINE" > "/tmp/vphone_proxy_${VM_DIR}.log" 2>&1 &
    PROXY_PID=$!
fi

# ── Wait for SSH ──────────────────────────────────────────────────────────────
wait_for_ssh

# ── Configure proxy on device ─────────────────────────────────────────────────
if [[ $PROXY_ACTIVE -eq 1 ]]; then
    sleep 3
    log "Configuring device proxy → 192.168.64.1:$PROXY_PORT"
    for proxy_attempt in 1 2 3; do
        if zsh scripts/proxy_setup_device.sh "$VM_DIR"; then
            break
        fi
        warn "proxy_setup_device.sh attempt $proxy_attempt failed, retrying in 5s..."
        sleep 5
    done
else
    log "Clearing device proxy (no --proxy-line)"
    zsh scripts/proxy_clear_device.sh "$VM_DIR" || true
fi

# ── Clear Safari identity ─────────────────────────────────────────────────────
if [[ $CLEAR_SAFARI -eq 1 ]]; then
    log "Clearing Safari and identity state..."
    ssh_cmd '
killall Safari mobilesafarid 2>/dev/null || true
rm -rf /var/mobile/Library/Safari
mkdir -p /var/mobile/Library/Safari
rm -f /var/mobile/Library/Cookies/Cookies.binarycookies \
      /var/mobile/Library/Cookies/com.apple.Safari.SafeBrowsing.binarycookies
rm -rf /var/mobile/Library/WebKit
rm -rf /var/mobile/Library/Caches/com.apple.Safari
rm -f /var/mobile/Library/Preferences/com.apple.Safari.plist \
      /var/mobile/Library/Preferences/com.apple.SafariServices.plist \
      /var/mobile/Library/Preferences/com.apple.SafariBookmarksSyncAgent.plist \
      /var/mobile/Library/Preferences/com.apple.Safari.SafeBrowsing.plist
find /var/Keychains -name "*.db" -type f 2>/dev/null | while read db; do
    sqlite3 "$db" "DELETE FROM genp WHERE agrp NOT LIKE '"'"'%apple%'"'"' AND agrp NOT LIKE '"'"'%ssh%'"'"';
                   DELETE FROM inet;" 2>/dev/null || true
done
rm -rf /var/mobile/Library/Caches/com.apple.NetworkServiceProxy
killall mDNSResponder 2>/dev/null || true
' || warn "Safari clear failed"
    sleep 2  # wait for mDNSResponder restart before next SSH call
fi

# ── WebRTC ────────────────────────────────────────────────────────────────────
if [[ $DISABLE_WEBRTC -eq 1 ]]; then
    log "Disabling WebRTC in Safari..."
    ssh_cmd '
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
echo "[+] WebRTC disabled"
' || warn "WebRTC disable failed — IP leak possible"
else
    log "Re-enabling WebRTC in Safari (no --webrtc-disable)..."
    ssh_cmd '
rm -f "/var/Managed Preferences/mobile/com.apple.WebKit.plist" 2>/dev/null || true
killall Safari 2>/dev/null || true
killall mobilesafarid 2>/dev/null || true
echo "[+] WebRTC re-enabled"
' || true
fi

# ── Timezone ──────────────────────────────────────────────────────────────────
if [[ -n "$TIMEZONE" ]]; then
    log "Setting timezone → $TIMEZONE"
    zsh scripts/set_timezone.sh "$VM_DIR" "$TIMEZONE" || warn "set_timezone.sh failed"
fi

# ── Frida SSH tunnel ──────────────────────────────────────────────────────────
log "Starting Frida tunnel → localhost:$FRIDA_LOCAL_PORT"
sshpass -p alpine ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PubkeyAuthentication=no \
    -o ConnectTimeout=10 -o ServerAliveInterval=30 \
    -N -L "${FRIDA_LOCAL_PORT}:127.0.0.1:27042" \
    -p "$SSH_PORT" "root@127.0.0.1" &
FRIDA_TUNNEL_PID=$!
sleep 1

# ── Ready ─────────────────────────────────────────────────────────────────────
echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "  $VM_DIR is running"
info "  SSH:   ssh root@127.0.0.1 -p $SSH_PORT  (pass: alpine)"
if [[ $PROXY_ACTIVE -eq 1 ]]; then
info "  Proxy: 192.168.64.1:$PROXY_PORT → $PROXY_MODE  (log: /tmp/vphone_proxy_${VM_DIR}.log)"
fi
info "  Frida: frida -H 127.0.0.1:$FRIDA_LOCAL_PORT -n Safari -l ~/vphone_camera_hook.js --keepalive-interval 5"
info ""
info "  Ctrl+C to stop VM + cleanup"
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

wait $BOOT_PID
