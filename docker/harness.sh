#!/usr/bin/env bash
set -euo pipefail

DSH_BIN="/home/sandbox/.npm-global/node_modules/@deepseek-ai/dsh/lib/bin.js"

DSH_HOST="127.0.0.1"
DSH_PORT="4090"
BRIDGE_HOST="0.0.0.0"
BRIDGE_PORT="4091"

RUNTIME_DIR="/run/ai-workstation-cli/harness"
DSH_PID_FILE="$RUNTIME_DIR/dsh.pid"
BRIDGE_PID_FILE="$RUNTIME_DIR/bridge.pid"
LOG_FILE="$RUNTIME_DIR/harness.log"

mkdir -p "$RUNTIME_DIR"

dsh_running() {
    [[ -f "$DSH_PID_FILE" ]] || return 1

    local pid
    pid="$(cat "$DSH_PID_FILE" 2>/dev/null || true)"

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    kill -0 "$pid" 2>/dev/null
}

bridge_running() {
    [[ -f "$BRIDGE_PID_FILE" ]] || return 1

    local pid
    pid="$(cat "$BRIDGE_PID_FILE" 2>/dev/null || true)"

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    kill -0 "$pid" 2>/dev/null
}

cleanup_stale_state() {
    if ! dsh_running; then
        rm -f "$DSH_PID_FILE"
    fi

    if ! bridge_running; then
        rm -f "$BRIDGE_PID_FILE"
    fi
}

start_dsh() {
    if dsh_running; then
        return 0
    fi

    echo "Starting DSH..."

    # Pin the invoking directory to the active project so the workspace
    # picker opens on project files instead of the sandbox HOME
    # (which holds only hidden files).
    cd /workspace 2>/dev/null || {
        echo "ERROR: workspace mount missing" >&2
        return 1
    }

    # Extra authorities the DSH /api browser-trust fence accepts
    # (e.g. the public Cloudflare hostname). Space/comma-separated
    # via DSH_TRUSTED_HOSTS; unset means local-only trust.
    local dsh_args=(web --host "$DSH_HOST" --port "$DSH_PORT" --no-open)
    local trusted="${DSH_TRUSTED_HOSTS:-}"
    local entry
    for entry in ${trusted//,/ }; do
        [[ -n "$entry" ]] && dsh_args+=(--trusted-host "$entry")
    done

    node --expose-internals "$DSH_BIN" \
        "${dsh_args[@]}" >>"$LOG_FILE" 2>&1 &

    echo "$!" > "$DSH_PID_FILE"
}

start_bridge() {
    if bridge_running; then
        return 0
    fi

    echo "Starting Harness bridge..."

    node -e '
        const net = require("net");

        const server = net.createServer((socket) => {
            const target = net.connect(4090, "127.0.0.1", () => {
                socket.pipe(target);
                target.pipe(socket);
            });

            target.on("error", () => socket.destroy());
            socket.on("error", () => target.destroy());
        });

        server.listen(4091, "0.0.0.0");
    ' >>"$LOG_FILE" 2>&1 &

    echo "$!" > "$BRIDGE_PID_FILE"
}

stop_process() {
    local pid_file="$1"

    [[ -f "$pid_file" ]] || return 0

    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"

    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        kill -TERM "$pid" 2>/dev/null || true

        for _ in {1..20}; do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi

            sleep 0.1
        done

        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$pid_file"
}

cmd_start() {
    cleanup_stale_state
    : > "$LOG_FILE"

    start_dsh

    # Give DSH a moment to bind before starting the bridge.
    for _ in {1..30}; do
        if (echo >/dev/tcp/127.0.0.1/4090) >/dev/null 2>&1; then
            break
        fi

        sleep 0.1
    done

    start_bridge

    echo "Harness started."
}

cmd_stop() {
    stop_process "$BRIDGE_PID_FILE"
    stop_process "$DSH_PID_FILE"

    echo "Harness stopped."
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_status() {
    cleanup_stale_state

    local dsh_status="stopped"
    local bridge_status="stopped"

    if dsh_running; then
        dsh_status="running"
    fi

    if bridge_running; then
        bridge_status="running"
    fi

    echo "=== Harness ==="
    echo "DSH:    $dsh_status"
    echo "Bridge: $bridge_status"

    if [[ "$dsh_status" == "running" && "$bridge_status" == "running" ]]; then
        return 0
    fi

    return 1
}

case "${1:-}" in
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        cmd_restart
        ;;
    status)
        cmd_status
        ;;
    *)
        echo "Usage: harness {start|stop|restart|status}"
        exit 1
        ;;
esac
