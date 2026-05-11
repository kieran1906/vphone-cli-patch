#!/usr/zsh
# proxy_start.sh — Start a proxy forwarder for a vphone VM.
#
# Usage:
#   ./scripts/proxy_start.sh vm2
#   ./scripts/proxy_start.sh vm2 --mode socks5
#   ./scripts/proxy_start.sh vm2 --mode http
#
# Port convention: 12320 + VM number (vm2 = 12322)
# The VM's iOS proxy should point to 192.168.64.1:<port>
#
# Environment:
#   PROXY_MODE        "socks5" or "http" (default: socks5)
#
#   SOCKS5 mode (coldproxy):
#     SOCKS5_UPSTREAM   Upstream SOCKS5 host:port (default: gw-98959.coldproxy.com:32466)
#     SOCKS5_AUTH_BASE  Base auth string (default: coldproxy user:pass without session)
#
#   HTTP mode (iproyal):
#     PROXY_UPSTREAM    Upstream proxy host:port (default: geo.iproyal.com:12321)
#     PROXY_AUTH_BASE   Base auth string before session suffix
#                       (default: iproyal user:pass_country-us)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VM_DIR="${1:?Usage: proxy_start.sh <VM_DIR> [--mode socks5|http]}"
shift

MODE="socks5"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="${2:?--mode requires socks5 or http}"; shift 2 ;;
        *) shift ;;
    esac
done

# Extract VM number for port
vm_num="${VM_DIR//[^0-9]/}"
vm_num="${vm_num:-1}"
PROXY_PORT=$(( 12320 + vm_num ))

# Generate unique session per VM
SESSION_ID="$(date +%s)_${vm_num}_$(head -c4 /dev/urandom | xxd -p)"

# Kill any existing proxy on this port
pkill -f "proxy_forwarder.*--port $PROXY_PORT" 2>/dev/null || true
lsof -ti tcp:$PROXY_PORT 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 1

if [[ "$MODE" == "socks5" ]]; then
    SOCKS5_UPSTREAM="${SOCKS5_UPSTREAM:-gw-98959.coldproxy.com:32466}"
    SOCKS5_AUTH_BASE="${SOCKS5_AUTH_BASE:-ljicgofzvs_98959-package-ipv4residential-country-US-session-REPLACE-time-3600s:P2bcaWxtPjmKH}"

    SOCKS5_AUTH_USER="$(echo "$SOCKS5_AUTH_BASE" | cut -d: -f1 | sed "s/REPLACE/${SESSION_ID}/")"
    SOCKS5_AUTH_PASS="$(echo "$SOCKS5_AUTH_BASE" | cut -d: -f2)"
    SOCKS5_AUTH="${SOCKS5_AUTH_USER}:${SOCKS5_AUTH_PASS}"

    echo "[socks5-proxy] VM: $VM_DIR  Port: $PROXY_PORT"
    echo "[socks5-proxy] Upstream: $SOCKS5_UPSTREAM"
    echo "[socks5-proxy] Session: $SESSION_ID"

    exec python3 "$REPO_DIR/scripts/proxy_forwarder_socks5.py" \
        --port "$PROXY_PORT" \
        --socks5 "$SOCKS5_UPSTREAM" \
        --socks5-auth "$SOCKS5_AUTH"

elif [[ "$MODE" == "http" ]]; then
    PROXY_UPSTREAM="${PROXY_UPSTREAM:-geo.iproyal.com:12321}"
    PROXY_AUTH_BASE="${PROXY_AUTH_BASE:-1kTBtpMnjijH4RH7:yNdruyJEECMTiwu2_country-us}"
    PROXY_AUTH="${PROXY_AUTH_BASE}_session-${SESSION_ID}_lifetime-10m"

    echo "[http-proxy] VM: $VM_DIR  Port: $PROXY_PORT"
    echo "[http-proxy] Upstream: $PROXY_UPSTREAM"
    echo "[http-proxy] Session: $(echo "$PROXY_AUTH" | grep -o 'session-[^_]*' || echo 'custom')"

    exec python3 "$REPO_DIR/scripts/proxy_forwarder.py" \
        --port "$PROXY_PORT" \
        --upstream "$PROXY_UPSTREAM" \
        --upstream-auth "$PROXY_AUTH"

else
    echo "Unknown mode: $MODE (use socks5 or http)"
    exit 1
fi
