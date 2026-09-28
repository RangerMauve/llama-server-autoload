#!/usr/bin/env bash
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
MODEL="openbmb/MiniCPM5-2B-GGUF:Q4_K_M"
SERVICE_NAME="llama-server"
HOST="127.0.0.1"
PORT=42424
BACKEND_PORT=42425
THREADS=$(( $(nproc) - 2 ))
PARALLEL=2
CTX_SIZE=131072
IDLE_TIMEOUT=1800  # seconds
TEMP=1.0
TOP_P=0.95
MIN_P=0.0

# ─── Parse args ─────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sets up a socket-activated, idle-unloading systemd user service for llama-server.

Options:
  -m, --model NAME        HuggingFace model for -hf flag (default: $MODEL)
  -s, --service NAME      Service base name (default: $SERVICE_NAME)
  -p, --port PORT         Public port (default: $PORT)
  -b, --backend-port PORT Internal backend port (default: $BACKEND_PORT)
  -t, --threads N         CPU threads (default: nproc - 2 = $THREADS)
  -n, --parallel N        Parallel slots (default: $PARALLEL)
  -c, --ctx-size N        Context size (default: $CTX_SIZE)
  -i, --idle-timeout SEC  Idle seconds before unload (default: $IDLE_TIMEOUT)
  --temp F                Temperature (default: $TEMP)
  --top-p F               Top-p (default: $TOP_P)
  --min-p F               Min-p (default: $MIN_P)
  -h, --help              Show this help

Examples:
  $(basename "$0")
  $(basename "$0") -m "ggml-org/gpt-oss-20b:Q4_K_M" -s gpt-oss -p 42426 -b 42427
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)       MODEL="$2"; shift 2 ;;
        -s|--service)     SERVICE_NAME="$2"; shift 2 ;;
        -p|--port)        PORT="$2"; shift 2 ;;
        -b|--backend-port) BACKEND_PORT="$2"; shift 2 ;;
        -t|--threads)     THREADS="$2"; shift 2 ;;
        -n|--parallel)    PARALLEL="$2"; shift 2 ;;
        -c|--ctx-size)    CTX_SIZE="$2"; shift 2 ;;
        -i|--idle-timeout) IDLE_TIMEOUT="$2"; shift 2 ;;
        --temp)           TEMP="$2"; shift 2 ;;
        --top-p)          TOP_P="$2"; shift 2 ;;
        --min-p)          MIN_P="$2"; shift 2 ;;
        -h|--help)        usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# ─── Derived paths ──────────────────────────────────────────────────────────
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BIN_DIR="${HOME}/.local/bin"
PROXYD="/usr/lib/systemd/systemd-socket-proxyd"
[[ -f "$PROXYD" ]] || PROXYD="/usr/lib64/systemd/systemd-socket-proxyd"

SOCKET_UNIT="${SERVICE_NAME}.socket"
PROXY_UNIT="${SERVICE_NAME}-proxy.service"
SERVER_UNIT="${SERVICE_NAME}.service"
IDLE_TIMER="${SERVICE_NAME}-idle-check.timer"
IDLE_SERVICE="${SERVICE_NAME}-idle-check.service"
PROXY_SCRIPT="${BIN_DIR}/${SERVICE_NAME}-proxy-wait.sh"
IDLE_SCRIPT="${BIN_DIR}/${SERVICE_NAME}-idle-check.sh"

# ─── Pre-flight ─────────────────────────────────────────────────────────────
command -v llama-server &>/dev/null || { echo "ERROR: llama-server not found in PATH" >&2; exit 1; }
[[ -f "$PROXYD" ]] || { echo "ERROR: systemd-socket-proxyd not found" >&2; exit 1; }
mkdir -p "$USER_UNIT_DIR" "$BIN_DIR"

echo "Setting up $SERVICE_NAME with model: $MODEL"
echo "  Port: $PORT (public) → $BACKEND_PORT (backend)"
echo "  Threads: $THREADS  Parallel: $PARALLEL  Ctx: $CTX_SIZE"
echo "  Idle timeout: ${IDLE_TIMEOUT}s"
echo ""

# ─── Write units ────────────────────────────────────────────────────────────
cat > "$USER_UNIT_DIR/$SOCKET_UNIT" <<EOF
[Unit]
Description=${SERVICE_NAME} socket proxy

[Socket]
ListenStream=${HOST}:${PORT}
Service=${PROXY_UNIT}
Backlog=16

[Install]
WantedBy=sockets.target
EOF

cat > "$USER_UNIT_DIR/$PROXY_UNIT" <<EOF
[Unit]
Description=Proxy connections to ${SERVICE_NAME}
Requires=${SERVER_UNIT}
After=${SERVER_UNIT}
Requires=${SOCKET_UNIT}
After=${SOCKET_UNIT}

[Service]
Type=notify
ExecStart=${PROXY_SCRIPT}
EOF

cat > "$USER_UNIT_DIR/$SERVER_UNIT" <<EOF
[Unit]
Description=Llama.cpp server - ${MODEL}

[Service]
Type=simple
ExecStart=$(command -v llama-server) \\
    -hf ${MODEL} \\
    --host ${HOST} \\
    --port ${BACKEND_PORT} \\
    --threads ${THREADS} \\
    --ctx-size ${CTX_SIZE} \\
    --parallel ${PARALLEL} \\
    --no-webui \\
    --flash-attn on \\
    --temp ${TEMP} \\
    --top-p ${TOP_P} \\
    --min-p ${MIN_P}
Restart=on-failure
RestartSec=5
Nice=-10

[Install]
WantedBy=default.target
EOF

cat > "$USER_UNIT_DIR/$IDLE_SERVICE" <<EOF
[Unit]
Description=Stop ${SERVICE_NAME} if idle for $((IDLE_TIMEOUT / 60))min
After=${SERVER_UNIT}

[Service]
Type=oneshot
ExecStart=${IDLE_SCRIPT}
EOF

cat > "$USER_UNIT_DIR/$IDLE_TIMER" <<EOF
[Unit]
Description=Check ${SERVICE_NAME} idle state every minute

[Timer]
OnBootSec=60
OnUnitActiveSec=60
Unit=${IDLE_SERVICE}

[Install]
WantedBy=timers.target
EOF

# ─── Write scripts ──────────────────────────────────────────────────────────
cat > "$PROXY_SCRIPT" <<EOF
#!/usr/bin/env bash
# Wait for ${SERVICE_NAME} to report healthy, then proxy.
until curl -sf http://${HOST}:${BACKEND_PORT}/health 2>/dev/null; do
    sleep 0.5
done
exec ${PROXYD} ${HOST}:${BACKEND_PORT}
EOF

cat > "$IDLE_SCRIPT" <<EOF
#!/usr/bin/env bash
# Stop ${SERVICE_NAME} if no established connections on port ${BACKEND_PORT} for $((IDLE_TIMEOUT / 60)) min.
PORT=${BACKEND_PORT}
IDLE_LIMIT=${IDLE_TIMEOUT}
TS_FILE="\${XDG_RUNTIME_DIR}/${SERVICE_NAME}.idle-timestamp"

# Is the server even running?
if ! systemctl --user is-active --quiet ${SERVER_UNIT}; then
    rm -f "\$TS_FILE"
    exit 0
fi

# Check for established connections on the port
if ss -tn state established "( sport = :\$PORT )" | grep -q .; then
    date +%s > "\$TS_FILE"
    exit 0
fi

# No connections. Check how long it's been idle.
if [[ -f "\$TS_FILE" ]]; then
    last_active=\$(cat "\$TS_FILE")
    now=\$(date +%s)
    idle=\$(( now - last_active ))
    if (( idle >= IDLE_LIMIT )); then
        echo "${SERVICE_NAME} idle for \${idle}s, stopping."
        systemctl --user stop ${SERVER_UNIT}
        rm -f "\$TS_FILE"
        exit 0
    fi
fi

# First run (no timestamp yet) — start the clock
[[ -f "\$TS_FILE" ]] || date +%s > "\$TS_FILE"
EOF

chmod +x "$PROXY_SCRIPT" "$IDLE_SCRIPT"

# ─── Enable ─────────────────────────────────────────────────────────────────
systemctl --user daemon-reload
systemctl --user enable --now "$SOCKET_UNIT"
systemctl --user enable --now "$IDLE_TIMER"

echo ""
echo "Done. Files created:"
echo "  $USER_UNIT_DIR/$SOCKET_UNIT"
echo "  $USER_UNIT_DIR/$PROXY_UNIT"
echo "  $USER_UNIT_DIR/$SERVER_UNIT"
echo "  $USER_UNIT_DIR/$IDLE_SERVICE"
echo "  $USER_UNIT_DIR/$IDLE_TIMER"
echo "  $PROXY_SCRIPT"
echo "  $IDLE_SCRIPT"
echo ""
echo "Server will cold-start on first request to http://${HOST}:${PORT}"
echo "Auto-unloads after $((IDLE_TIMEOUT / 60)) minutes of inactivity."
echo ""
echo "Test: curl http://${HOST}:${PORT}/health"
