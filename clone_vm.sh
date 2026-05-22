#!/bin/zsh
# clone_vm.sh — Clone an existing provisioned VM, boot it, wipe browser/identity
#               state, and optionally install tweaks (.deb) and IPAs over SSH.
#
# Usage:
#   ./clone_vm.sh <SOURCE_VM> <NEW_VM> [--tweaks "url1 url2 ..."] [--ipas "url1 url2 ..."]
#
# Args:
#   <SOURCE_VM>     Existing VM directory to clone from
#   <NEW_VM>        Name for the new VM directory
#   --tweaks "..."  Space-separated list of .deb URLs or local paths to install (optional)
#   --ipas   "..."  Space-separated list of .ipa URLs or local paths to install (optional)
#
# Examples:
#   ./clone_vm.sh vm2 vm3
#   ./clone_vm.sh vm2 vm3 --ipas "/path/to/app.ipa"
#   ./clone_vm.sh vm2 vm3 --ipas "https://example.com/app.ipa"
#   ./clone_vm.sh vm2 vm3 --tweaks "https://example.com/tweak1.deb /local/tweak2.deb"
#   ./clone_vm.sh vm2 vm3 --tweaks "https://example.com/t.deb" --ipas "/path/to/app.ipa"

set -euo pipefail
cd "$(dirname "$0")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[clone]${NC} $*"; }
warn() { echo -e "${YELLOW}[clone]${NC} $*"; }
die()  { echo -e "${RED}[clone] FATAL:${NC} $*"; exit 1; }

USAGE='Usage: ./clone_vm.sh <SOURCE_VM> <NEW_VM> [--tweaks "url1 url2 ..."] [--ipas "url1 url2 ..."]'

[[ -n "${1:-}" ]] || die "$USAGE"
[[ -n "${2:-}" ]] || die "$USAGE"

SRC="$1"
DST="$2"
TWEAKS_URLS=()
IPAS_URLS=()

shift 2
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tweaks)
            [[ -n "${2:-}" ]] || die "--tweaks requires a value"
            TWEAKS_URLS=( ${=2} )
            shift 2
            ;;
        --ipas)
            [[ -n "${2:-}" ]] || die "--ipas requires a value"
            IPAS_URLS=( ${=2} )
            shift 2
            ;;
        *) die "Unknown argument: $1  ($USAGE)" ;;
    esac
done

# ── Validate ──────────────────────────────────────────────────────────────────
[[ -d "$SRC" ]] || die "Source VM not found: $SRC"
[[ ! -d "$DST" ]] || die "Destination already exists: $DST"

# ── APFS clone ────────────────────────────────────────────────────────────────
log "Cloning $SRC → $DST (APFS copy-on-write)"
cp -rc "$SRC" "$DST"

log "Clearing machineIdentifier (new UDID will be generated on first boot)"
plutil -replace machineIdentifier -data "" "$DST/config.plist"

log "Clone complete."

# ── SSH helpers ───────────────────────────────────────────────────────────────
vm_num="${DST//[^0-9]/}"
vm_num="${vm_num:-1}"
SSH_PORT=$(( 2230 + vm_num ))
SSH_HOST="127.0.0.1"
SSH_USER="root"
SSH_PASS="alpine"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o IdentitiesOnly=yes -o PreferredAuthentications=password -o ConnectTimeout=10 -o LogLevel=ERROR)

ssh_cmd() {
    sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "$@"
}

scp_to() {
    sshpass -p "$SSH_PASS" scp "${SSH_OPTS[@]}" -P "$SSH_PORT" "$1" "$SSH_USER@$SSH_HOST:$2"
}

wait_for_ssh() {
    log "Waiting for SSH on port $SSH_PORT (up to 10 min)..."
    for i in $(seq 1 120); do
        if ssh_cmd 'echo ok' 2>/dev/null | grep -q '^ok$'; then
            return 0
        fi
        sleep 5
    done
    die "SSH on port $SSH_PORT did not become available after 10 min"
}

# ── Clear stale SSH known_hosts entry for this port ──────────────────────────
ssh-keygen -R "[127.0.0.1]:${SSH_PORT}" 2>/dev/null || true

# ── Boot ──────────────────────────────────────────────────────────────────────
log "Booting $DST (SSH port: $SSH_PORT)..."
make VM_DIR="$DST" boot > "/tmp/vphone_boot_${DST}.log" 2>&1 &

wait_for_ssh

# ── Ensure trollstorehelper is on PATH ────────────────────────────────────────
log "Checking trollstorehelper..."
ssh_cmd 'readlink /var/jb' > /dev/null 2>&1 || warn "  /var/jb not ready — trollstorehelper lookup will use find fallback"

# ── Temp dir for downloads ────────────────────────────────────────────────────
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

# fetch_file <src> <dest> — copies a local path or downloads a URL to <dest>
fetch_file() {
    local src="$1" dest="$2"
    if [[ -f "$src" ]]; then
        log "  Copying local file: $src"
        cp "$src" "$dest"
    else
        log "  Downloading: $src"
        curl -fsSL -o "$dest" "$src" || die "Failed to download: $src"
    fi
}

# ── Install tweaks (.deb) ─────────────────────────────────────────────────────
if [[ ${#TWEAKS_URLS[@]} -gt 0 ]]; then
    log "Installing ${#TWEAKS_URLS[@]} tweak(s)..."
    i=0
    for src in "${TWEAKS_URLS[@]}"; do
        i=$(( i + 1 ))
        deb="$TEMP_DIR/tweak_${i}.deb"
        log "  [$i/${#TWEAKS_URLS[@]}]"
        fetch_file "$src" "$deb"
        scp_to "$deb" "/tmp/tweak_${i}.deb"
        log "  [$i/${#TWEAKS_URLS[@]}] Installing..."
        ssh_cmd "dpkg -i /tmp/tweak_${i}.deb; apt --fix-broken install -y -qq 2>/dev/null || true; rm -f /tmp/tweak_${i}.deb" \
            || warn "Install failed for $(basename "$src") — continuing"
    done
    log "Tweaks installed."
fi

# ── Install IPAs ──────────────────────────────────────────────────────────────
if [[ ${#IPAS_URLS[@]} -gt 0 ]]; then
    log "Installing ${#IPAS_URLS[@]} IPA(s)..."
    i=0
    for src in "${IPAS_URLS[@]}"; do
        i=$(( i + 1 ))
        ipa="$TEMP_DIR/app_${i}.ipa"
        log "  [$i/${#IPAS_URLS[@]}]"
        fetch_file "$src" "$ipa"
        scp_to "$ipa" "/tmp/app_${i}.ipa"
        log "  [$i/${#IPAS_URLS[@]}] Installing..."
        rc=0
        ssh_cmd "tsh=\$(find \$(readlink /var/jb) -name trollstorehelper -type f 2>/dev/null | head -1) && \"\$tsh\" install /tmp/app_${i}.ipa; rm -f /tmp/app_${i}.ipa" || rc=$?
        # exit 184 = app has encrypted extensions but main app installed fine
        [[ $rc -eq 0 || $rc -eq 184 ]] || warn "trollstorehelper failed (exit $rc) for $(basename "$src") — continuing"
    done
    log "IPAs installed."
fi

# ── Wipe browser & identity state ─────────────────────────────────────────────
log "Wiping browser and identity state..."
ssh_cmd '
killall Safari mobilesafarid 2>/dev/null || true

# Nuke entire Safari directory and recreate empty
rm -rf /var/mobile/Library/Safari
mkdir -p /var/mobile/Library/Safari

# Cookies
rm -f /var/mobile/Library/Cookies/Cookies.binarycookies \
      /var/mobile/Library/Cookies/com.apple.Safari.SafeBrowsing.binarycookies \
      2>/dev/null || true

# WebKit storage (localStorage, IndexedDB, service workers, HSTS)
rm -rf /var/mobile/Library/WebKit 2>/dev/null || true

# Safari cache
rm -rf /var/mobile/Library/Caches/com.apple.Safari 2>/dev/null || true

# Safari preferences (autofill, saved form data, per-site settings)
rm -f /var/mobile/Library/Preferences/com.apple.Safari.plist \
      /var/mobile/Library/Preferences/com.apple.SafariServices.plist \
      /var/mobile/Library/Preferences/com.apple.SafariBookmarksSyncAgent.plist \
      /var/mobile/Library/Preferences/com.apple.Safari.SafeBrowsing.plist \
      2>/dev/null || true

# Keychain — web credentials only (genp=generic, inet=internet passwords)
# Skip cert/keys tables to avoid breaking SSH host keys
find /var/Keychains -name "*.db" -type f 2>/dev/null | while read db; do
    sqlite3 "$db" "DELETE FROM genp WHERE agrp NOT LIKE '%apple%' AND agrp NOT LIKE '%ssh%';
                   DELETE FROM inet;" 2>/dev/null || true
done

# TLS session ticket cache
rm -rf /var/mobile/Library/Caches/com.apple.NetworkServiceProxy 2>/dev/null || true

# DNS cache flush
killall mDNSResponder 2>/dev/null || true

echo "[+] Browser and identity state wiped"
' || warn "State wipe failed — continuing"

# ── Refresh SpringBoard app cache ─────────────────────────────────────────────
log "Refreshing app cache (uicache)..."
ssh_cmd "uicache -a 2>/dev/null || true" || true

log "All done. $DST is running on SSH port $SSH_PORT."
log "  ssh root@$SSH_HOST -p $SSH_PORT   (pass: $SSH_PASS)"
log "  To boot next time: ./boot_vm.sh $DST [--proxy]"
