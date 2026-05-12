#!/bin/zsh
# set_timezone.sh — Set timezone on a vphone VM, disabling automatic timezone.
#
# Usage:
#   ./scripts/set_timezone.sh <VM_DIR> <TIMEZONE>
#
# Examples:
#   ./scripts/set_timezone.sh vm2 America/New_York
#   ./scripts/set_timezone.sh vm2 Europe/London
#   ./scripts/set_timezone.sh vm2 Asia/Tokyo

set -euo pipefail

VM_DIR="${1:?Usage: set_timezone.sh <VM_DIR> <TIMEZONE>}"
TIMEZONE="${2:?Usage: set_timezone.sh <VM_DIR> <TIMEZONE>}"

vm_num="${VM_DIR//[^0-9]/}"
vm_num="${vm_num:-1}"
SSH_PORT=$(( 2230 + vm_num ))

SSH_CMD=(sshpass -p alpine ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o IdentitiesOnly=yes -o PreferredAuthentications=password -o ConnectTimeout=10 root@127.0.0.1 -p "$SSH_PORT")

echo "[timezone] VM: $VM_DIR  SSH: $SSH_PORT  TZ: $TIMEZONE"

if ! "${SSH_CMD[@]}" "echo ok" 2>/dev/null | grep -q ok; then
    echo "[-] SSH not available on port $SSH_PORT"
    exit 1
fi

"${SSH_CMD[@]}" "
ZONEINFO_PATH=\"/var/db/timezone/zoneinfo/${TIMEZONE}\"

if [ ! -f \"\$ZONEINFO_PATH\" ]; then
    echo \"[-] Timezone not found: \$ZONEINFO_PATH\"
    exit 1
fi

# Update the localtime symlink
ln -sf \"\$ZONEINFO_PATH\" /var/db/timezone/localtime

# Disable automatic timezone via managed prefs
MANAGED_DIR='/var/Managed Preferences/mobile'
mkdir -p \"\$MANAGED_DIR\"
cat > \"\$MANAGED_DIR/com.apple.preferences.datetime.plist\" << PLIST
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>TimeZone</key>
  <string>${TIMEZONE}</string>
  <key>AutomaticDateTime</key>
  <false/>
</dict>
</plist>
PLIST

echo \"[+] Timezone set to ${TIMEZONE}\"
echo \"[+] Automatic timezone disabled\"
" 2>&1

echo "[timezone] Done"
