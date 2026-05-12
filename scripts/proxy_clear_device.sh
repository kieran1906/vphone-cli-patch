#!/bin/zsh
# proxy_clear_device.sh — Turn off the system HTTP proxy on a vphone VM.
#
# Usage:
#   ./scripts/proxy_clear_device.sh <VM_DIR>

set -euo pipefail

vm_num="${1//[^0-9]/}"
vm_num="${vm_num:-1}"
SSH_PORT=$(( 2230 + vm_num ))
SSH_CMD=(sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o IdentitiesOnly=yes -o PreferredAuthentications=password root@127.0.0.1 -p "$SSH_PORT")

"${SSH_CMD[@]}" "
PREFS='/private/var/preferences/SystemConfiguration/preferences.plist'

UUID=''
for uuid in \$(plutil \"\$PREFS\" 2>/dev/null | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'); do
    if plutil -key NetworkServices -key \"\$uuid\" -key Interface -key DeviceName \"\$PREFS\" 2>/dev/null | grep -q '^en0$'; then
        UUID=\"\$uuid\"
        break
    fi
done

[ -z \"\$UUID\" ] && exit 0

plutil -key NetworkServices -key \"\$UUID\" -key Proxies -key HTTPEnable    -value 0 -type int \"\$PREFS\"
plutil -key NetworkServices -key \"\$UUID\" -key Proxies -key HTTPSEnable   -value 0 -type int \"\$PREFS\"
plutil -key NetworkServices -key \"\$UUID\" -key Proxies -key HTTPProxyType -value 0 -type int \"\$PREFS\"

# Also clear managed preferences — CFNetwork uses this as the global proxy
# and it overrides SystemConfiguration (Settings shows Off but traffic still proxied)
rm -f '/var/Managed Preferences/mobile/com.apple.proxy.http.global.plist' 2>/dev/null || true


killall configd 2>/dev/null || true
" 2>&1 && echo "[boot] Proxy cleared on $1" || true
