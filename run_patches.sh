#!/bin/bash
# run_patches.sh — Apply vphone-cli patches to a cloned repo.
#
# Usage:
#   ./run_patches.sh /path/to/vphone-cli

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[patch]${NC} $*"; }
warn() { echo -e "${YELLOW}[patch]${NC} $*"; }
die()  { echo -e "${RED}[patch] FATAL:${NC} $*"; exit 1; }

# ── Require repo path argument ─────────────────────────────────────────────────
if [[ -z "${1:-}" ]]; then
    die "Usage: ./run_patches.sh /path/to/vphone-cli"
fi

REPO="$(cd "$1" && pwd)"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Validate it looks like the right repo ──────────────────────────────────────
[[ -d "$REPO" ]]          || die "Directory not found: $REPO"
[[ -f "$REPO/Makefile" ]] || die "No Makefile found at $REPO — is this the vphone-cli repo?"
[[ -d "$REPO/scripts" ]]  || die "No scripts/ directory found at $REPO"

log "Applying patches to: $REPO"
echo ""

copy_file() {
    local rel="$1"
    local src="$PATCH_DIR/$rel"
    local dst="$REPO/$rel"
    [[ -f "$src" ]] || die "Patch file missing: $src"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    log "  $rel"
}

# ── Scripts ────────────────────────────────────────────────────────────────────
copy_file "CLAUDE.local.md"
copy_file "VPHONE-CLI_SETUP-GUIDE.md"
copy_file "provision_device.sh"
copy_file "scripts/cfw_install.sh"
copy_file "scripts/cfw_install_jb.sh"
copy_file "scripts/setup_tools.sh"
copy_file "scripts/setup_venv.sh"
copy_file "scripts/vphone_jb_setup.sh"
copy_file "scripts/vphone_sshd_start.sh"

# ── Python automation ──────────────────────────────────────────────────────────
copy_file "device.py"

# ── Frida agents (TypeScript source + pre-compiled JS) ────────────────────────
copy_file "agent/screenshot.ts"
copy_file "agent/screenshot_agent.js"
copy_file "agent/accessibility.ts"
copy_file "agent/accessibility_agent.js"

# ── Swift source files ─────────────────────────────────────────────────────────
copy_file "sources/vphone-cli/VPhoneTouchServer.swift"
copy_file "sources/vphone-cli/VPhoneWindowController.swift"
copy_file "sources/vphone-cli/VPhoneVirtualMachineView.swift"

# ── Permissions ────────────────────────────────────────────────────────────────
chmod +x "$REPO/provision_device.sh"
chmod +x "$REPO/scripts/"*.sh

echo ""
log "All patches applied."
echo ""
echo "  Rebuild the app:   cd $REPO && make"
echo "  Install pip deps:  pip3 install frida pymobiledevice3 sshpass"
echo ""
