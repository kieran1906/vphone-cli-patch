#!/bin/zsh
# proxy_setup_device.sh — Configure iOS system HTTP proxy on a vphone VM.
#
# Writes to /var/Managed Preferences/mobile/com.apple.proxy.http.global.plist
# which CFNetwork checks for a global proxy on all interfaces (including virtual
# ethernet en0 used by Virtualization.framework VMs).
#
# Usage (from Mac):
#   ./scripts/proxy_setup_device.sh vm2
#   ./scripts/proxy_setup_device.sh vm2 192.168.64.1 12322
#
# Port convention: 12320 + VM number
# Gateway is always 192.168.64.1 (Virtualization.framework NAT)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIMD="$REPO_DIR/.limd/bin"
VM_DIR="${1:?Usage: proxy_setup_device.sh <VM_DIR> [proxy_host] [proxy_port]}"

# Extract VM number
vm_num="${VM_DIR//[^0-9]/}"
vm_num="${vm_num:-1}"
SSH_PORT=$(( 2230 + vm_num ))
PROXY_HOST="${2:-192.168.64.1}"
PROXY_PORT="${3:-$(( 12320 + vm_num ))}"

echo "[proxy-device] VM: $VM_DIR  SSH: $SSH_PORT  Proxy: $PROXY_HOST:$PROXY_PORT"

# Find UDID
UDID=$("$LIMD/idevice_id" -l 2>/dev/null | head -1)
if [[ -z "$UDID" ]]; then
    echo "[-] No device found via idevice_id"
    exit 1
fi
echo "[proxy-device] UDID: $UDID"

# Ensure iproxy is running
if ! lsof -ti tcp:$SSH_PORT &>/dev/null; then
    echo "[proxy-device] Starting iproxy on port $SSH_PORT"
    "$LIMD/iproxy" -u "$UDID" "$SSH_PORT" 22 &
    sleep 2
fi

SSH_CMD=(sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 root@127.0.0.1 -p $SSH_PORT)

# Test SSH
echo "[proxy-device] Testing SSH on port $SSH_PORT..."
if ! "${SSH_CMD[@]}" "echo ok" 2>/dev/null | grep -q ok; then
    echo "[-] SSH not available on port $SSH_PORT — is the device booted and SSH running?"
    exit 1
fi
echo "[proxy-device] SSH OK"

echo "[proxy-device] Configuring proxy in SystemConfiguration (same path as iOS Settings)..."

"${SSH_CMD[@]}" "
PREFS='/private/var/preferences/SystemConfiguration/preferences.plist'

# Find the network service UUID for en0
UUID=''
for uuid in \$(plutil \"\$PREFS\" 2>/dev/null | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'); do
    if plutil -key NetworkServices -key \"\$uuid\" -key Interface -key DeviceName \"\$PREFS\" 2>/dev/null | grep -q '^en0$'; then
        UUID=\"\$uuid\"
        break
    fi
done

if [ -z \"\$UUID\" ]; then
    echo '[-] Could not find en0 service UUID'
    exit 1
fi
echo \"[+] en0 UUID: \$UUID\"

# Backup
cp \"\$PREFS\" \"\${PREFS}.bak\" 2>/dev/null || true

# Write exactly what iOS Settings writes — including HTTPProxyType=1 which is required
plutil -key NetworkServices -key \"\$UUID\" -key Proxies -key HTTPEnable          -value 1              -type int    \"\$PREFS\"
plutil -key NetworkServices -key \"\$UUID\" -key Proxies -key HTTPProxy            -value '$PROXY_HOST'  -type string \"\$PREFS\"
plutil -key NetworkServices -key \"\$UUID\" -key Proxies -key HTTPPort             -value $PROXY_PORT    -type int    \"\$PREFS\"
plutil -key NetworkServices -key \"\$UUID\" -key Proxies -key HTTPSEnable          -value 1              -type int    \"\$PREFS\"
plutil -key NetworkServices -key \"\$UUID\" -key Proxies -key HTTPSProxy           -value '$PROXY_HOST'  -type string \"\$PREFS\"
plutil -key NetworkServices -key \"\$UUID\" -key Proxies -key HTTPSPort            -value $PROXY_PORT    -type int    \"\$PREFS\"
plutil -key NetworkServices -key \"\$UUID\" -key Proxies -key HTTPProxyType        -value 1              -type int    \"\$PREFS\"
plutil -key NetworkServices -key \"\$UUID\" -key Proxies -key HTTPProxyAuthenticated -value 0            -type int    \"\$PREFS\"

echo '[+] Proxy keys written'
plutil \"\$PREFS\" 2>/dev/null | grep -E 'HTTP(S)?(Enable|Proxy|Port|ProxyType|ProxyAuthenticated)' | head -12

# Hard-kill configd so it fully re-reads preferences on restart
killall configd 2>/dev/null || true
echo '[+] configd restarted'
" 2>&1

echo "[proxy-device] Done — proxy set to $PROXY_HOST:$PROXY_PORT"
echo "[proxy-device] Force-quit Safari then reopen to apply."
