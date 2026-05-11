#!/bin/zsh
# proxy_start.sh — Start a proxy forwarder for a vphone VM.
#
# Usage:
#   ./scripts/proxy_start.sh vm2
#   ./scripts/proxy_start.sh vm2 "user:pass_country-us_session-abc123_lifetime-10m"
#
# Port convention: 12320 + VM number (vm2 = 12322)
# The VM's iOS proxy should point to 192.168.64.1:<port>
#
# Environment:
#   PROXY_UPSTREAM    Upstream proxy host:port (default: geo.iproyal.com:12321)
#   PROXY_AUTH_BASE   Base auth string before session suffix
#                     (default: 1kTBtpMnjijH4RH7:yNdruyJEECMTiwu2_country-us)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VM_DIR="${1:?Usage: proxy_start.sh <VM_DIR> [auth_string]}"

# Extract VM number for port
vm_num="${VM_DIR//[^0-9]/}"
vm_num="${vm_num:-1}"
PROXY_PORT=$(( 12320 + vm_num ))

# Upstream proxy
PROXY_UPSTREAM="${PROXY_UPSTREAM:-geo.iproyal.com:12321}"

# Auth — use explicit arg, or generate unique session per VM
if [[ -n "${2:-}" ]]; then
    PROXY_AUTH="$2"
else
    PROXY_AUTH_BASE="${PROXY_AUTH_BASE:-1kTBtpMnjijH4RH7:yNdruyJEECMTiwu2_country-us}"
    SESSION_ID="vphone${vm_num}_$(head -c4 /dev/urandom | xxd -p)"
    PROXY_AUTH="${PROXY_AUTH_BASE}_session-${SESSION_ID}_lifetime-10m"
fi

echo "[proxy] VM: $VM_DIR  Port: $PROXY_PORT"
echo "[proxy] Upstream: $PROXY_UPSTREAM"
echo "[proxy] Session: $(echo "$PROXY_AUTH" | grep -o 'session-[^_]*' || echo 'custom')"

# Kill any existing proxy on this port
pkill -f "proxy_forwarder.py.*--port $PROXY_PORT" 2>/dev/null || true
lsof -ti tcp:$PROXY_PORT 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 1

# Start proxy forwarder
exec python3 "$REPO_DIR/scripts/proxy_forwarder.py" \
    --port "$PROXY_PORT" \
    --upstream "$PROXY_UPSTREAM" \
    --upstream-auth "$PROXY_AUTH"
