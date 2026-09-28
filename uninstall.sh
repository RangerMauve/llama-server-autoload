#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="llama-server"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Removes all units and scripts created by setup.sh.

Options:
  -s, --service NAME   Service base name (default: $SERVICE_NAME)
  -h, --help           Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--service) SERVICE_NAME="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BIN_DIR="${HOME}/.local/bin"

SOCKET_UNIT="${SERVICE_NAME}.socket"
PROXY_UNIT="${SERVICE_NAME}-proxy.service"
SERVER_UNIT="${SERVICE_NAME}.service"
IDLE_TIMER="${SERVICE_NAME}-idle-check.timer"
IDLE_SERVICE="${SERVICE_NAME}-idle-check.service"
PROXY_SCRIPT="${BIN_DIR}/${SERVICE_NAME}-proxy-wait.sh"
IDLE_SCRIPT="${BIN_DIR}/${SERVICE_NAME}-idle-check.sh"

echo "Uninstalling $SERVICE_NAME..."

# Stop and disable
systemctl --user stop "$SOCKET_UNIT" "$SERVER_UNIT" "$IDLE_TIMER" 2>/dev/null || true
systemctl --user disable "$SOCKET_UNIT" "$IDLE_TIMER" 2>/dev/null || true

# Remove units
rm -fv \
    "$USER_UNIT_DIR/$SOCKET_UNIT" \
    "$USER_UNIT_DIR/$PROXY_UNIT" \
    "$USER_UNIT_DIR/$SERVER_UNIT" \
    "$USER_UNIT_DIR/$IDLE_SERVICE" \
    "$USER_UNIT_DIR/$IDLE_TIMER"

# Remove scripts
rm -fv "$PROXY_SCRIPT" "$IDLE_SCRIPT"

systemctl --user daemon-reload

echo "Done."
