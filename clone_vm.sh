#!/bin/zsh
# clone_vm.sh — Clone an existing provisioned VM into a new one.
#
# Usage:
#   ./scripts/clone_vm.sh <SOURCE_VM> <NEW_VM>
#
# Example:
#   ./scripts/clone_vm.sh vm1 vm3
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[clone]${NC} $*"; }
die() { echo -e "${RED}[clone] FATAL:${NC} $*"; exit 1; }

[[ -n "${1:-}" ]] || die "Usage: ./scripts/clone_vm.sh <SOURCE_VM> <NEW_VM>"
[[ -n "${2:-}" ]] || die "Usage: ./scripts/clone_vm.sh <SOURCE_VM> <NEW_VM>"

SRC="$1"
DST="$2"

[[ -d "$SRC" ]] || die "Source VM not found: $SRC"
[[ ! -d "$DST" ]] || die "Destination already exists: $DST"

log "Cloning $SRC → $DST (APFS copy-on-write)"
cp -rc "$SRC" "$DST"

log "Clearing machineIdentifier (new UDID will be generated on first boot)"
plutil -replace machineIdentifier -data "" "$DST/config.plist"

log "Done — boot with: make VM_DIR=$DST boot"
