#!/usr/bin/env bash
set -euo pipefail

RESOLVED_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$RESOLVED_SOURCE" ]; do
    TARGET="$(readlink "$RESOLVED_SOURCE")"
    if [[ "$TARGET" == /* ]]; then
        RESOLVED_SOURCE="$TARGET"
    else
        RESOLVED_SOURCE="$(dirname "$RESOLVED_SOURCE")/$TARGET"
    fi
done
SCRIPT_ROOT="$(cd "$(dirname "$RESOLVED_SOURCE")/../.." && pwd)"
ROOT="${AIWS_ROOT:-$SCRIPT_ROOT}"
if [[ ! -d "$ROOT" || ! -f "$ROOT/broker/github_broker.py" ]]; then
    ROOT="$SCRIPT_ROOT"
fi
ENV_FILE="$ROOT/.env"
SECRETS_DIR="$ROOT/secrets"
RUNTIME_DIR="$ROOT/runtime"
BROKER_DIR="$RUNTIME_DIR/github-broker"
PEM_FILE="$SECRETS_DIR/github-app.pem"
BROKER_SOCKET="$BROKER_DIR/github.sock"
BROKER_SCRIPT="$ROOT/broker/github_broker.py"
SERVICE_NAME="ai-github-broker"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HELPER="$ROOT/docker/github-app-credential-helper"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

set_env() {
    local key="$1"
    local value="$2"

    touch "$ENV_FILE"

    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

github_ensure_service() {
    local current_user
    current_user="${SUDO_USER:-$(id -un)}"
    if [[ "$current_user" == "root" && -n "${SUDO_USER:-}" ]]; then
        current_user="$SUDO_USER"
    fi
    if [[ "$current_user" == "root" ]]; then
        local root_owner
        root_owner="$(stat -c '%U' "$ROOT" 2>/dev/null || stat -f '%Su' "$ROOT" 2>/dev/null || echo "")"
        if [[ -n "$root_owner" && "$root_owner" != "root" ]]; then
            current_user="$root_owner"
        fi
    fi

    run_elevated() {
        if [[ "$(id -u)" -eq 0 ]]; then
            "$@"
        elif sudo -n true 2>/dev/null; then
            sudo -n "$@"
        else
            sudo "$@"
        fi
    }

    if ! getent group ai-broker >/dev/null 2>&1; then
        run_elevated groupadd --system ai-broker 2>/dev/null || true
    fi

    if getent group ai-broker >/dev/null 2>&1; then
        local broker_gid
        broker_gid="$(getent group ai-broker | cut -d: -f3)"
        set_env GITHUB_BROKER_GID "$broker_gid"
    fi
    set_env GITHUB_BROKER_SOCKET "$BROKER_SOCKET"
    set_env AIWS_ROOT "$ROOT"

    if ! id -nG "$current_user" 2>/dev/null | grep -qw "ai-broker"; then
        run_elevated usermod -aG ai-broker "$current_user" 2>/dev/null || true
    fi

    mkdir -p "$SECRETS_DIR" "$BROKER_DIR"
    chmod 700 "$SECRETS_DIR"
    run_elevated chown -R "$current_user" "$SECRETS_DIR" 2>/dev/null || true

    if getent group ai-broker >/dev/null 2>&1; then
        run_elevated chown -R "$current_user":ai-broker "$BROKER_DIR" 2>/dev/null || chown -R "$current_user" "$BROKER_DIR" 2>/dev/null || true
        run_elevated chmod 770 "$BROKER_DIR" 2>/dev/null || chmod 770 "$BROKER_DIR" 2>/dev/null || true
    else
        chmod 770 "$BROKER_DIR" 2>/dev/null || true
    fi

    local py_bin="$ROOT/.venv/bin/python"
    [[ -x "$py_bin" ]] || py_bin="$(command -v python3)"

    local write_service_cmd="tee"
    if [[ "$(id -u)" -ne 0 ]]; then
        if sudo -n true 2>/dev/null; then
            write_service_cmd="sudo -n tee"
        else
            write_service_cmd="sudo tee"
        fi
    fi

    if $write_service_cmd "$SERVICE_FILE" >/dev/null 2>&1 <<SERVICE
[Unit]
Description=AIWS GitHub App Credential Broker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$current_user
Group=ai-broker

WorkingDirectory=$ROOT

Environment=AIWS_ROOT=$ROOT

ExecStart=$py_bin $BROKER_SCRIPT

Restart=always
RestartSec=3

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only

ReadWritePaths=$RUNTIME_DIR

[Install]
WantedBy=multi-user.target
SERVICE
    then
        run_elevated systemctl daemon-reload 2>/dev/null || true
        run_elevated systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    mkdir -p "$ROOT/docker"

    cat > "$HELPER" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-get}" in
    get)
        node - <<'NODE'
const net = require("net");

let input = "";

process.stdin.setEncoding("utf8");

process.stdin.on("data", chunk => {
    input += chunk;
});

process.stdin.on("end", () => {
    const socket = net.createConnection(
        "/run/ai-github-broker/github.sock"
    );

    socket.on("connect", () => {
        socket.end(input);
    });

    socket.on("data", data => {
        process.stdout.write(data);
    });

    socket.on("error", () => {
        process.exit(1);
    });
});
NODE
        ;;
    store|erase)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
HELPER

    chmod +x "$HELPER"
}

github_start_broker() {
    # 1. If running as root, call systemctl directly
    if [[ "$(id -u)" -eq 0 ]]; then
        systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
        if systemctl restart "$SERVICE_NAME" 2>/dev/null; then
            return 0
        fi
    fi

    # 2. Try systemctl via non-interactive sudo if permitted
    if sudo -n systemctl reset-failed "$SERVICE_NAME" 2>/dev/null && sudo -n systemctl restart "$SERVICE_NAME" 2>/dev/null; then
        return 0
    fi

    # 3. Try direct systemctl if user has permissions
    if systemctl reset-failed "$SERVICE_NAME" 2>/dev/null && systemctl restart "$SERVICE_NAME" 2>/dev/null; then
        return 0
    fi

    # 4. Direct user process fallback (no sudo needed at all)
    local pid_file="$BROKER_DIR/broker.pid"
    if [[ -f "$pid_file" ]]; then
        local old_pid
        old_pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            kill -TERM "$old_pid" 2>/dev/null || true
            sleep 0.3
        fi
        rm -f "$pid_file"
    fi
    mkdir -p "$BROKER_DIR"
    local py_bin="$ROOT/.venv/bin/python"
    [[ -x "$py_bin" ]] || py_bin="$(command -v python3)"
    "$py_bin" "$BROKER_SCRIPT" >> "$BROKER_DIR/broker.log" 2>&1 &
    echo $! > "$pid_file"
}

github_setup() {
    local app_id="${1:-}"
    local installation_id="${2:-}"
    local pem_input="${3:-}"

    [[ -f "$BROKER_SCRIPT" ]] ||
        die "GitHub broker not found."

    [[ -f "$ROOT/docker/compose.yml" ]] ||
        die "Docker Compose file not found."

    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"

    if [[ -z "$app_id" || -z "$installation_id" || -z "$pem_input" ]]; then
        echo
        
        print_header "GITHUB APP SETUP"
        
        echo

        echo -e -n "\033[90mGitHub App ID:\033[0m "; read -r app_id
        [[ "$app_id" =~ ^[0-9]+$ ]] ||
            die "Invalid App ID."

        echo -e -n "\033[90mGitHub Inst ID:\033[0m "; read -r installation_id
        [[ "$installation_id" =~ ^[0-9]+$ ]] ||
            die "Invalid Installation ID."

        echo
        echo -e -n "\033[90mPrivate Key (.pem) Path :\033[0m "; read -r pem_input
    fi

    [[ "$app_id" =~ ^[0-9]+$ ]] ||
        die "Invalid App ID: $app_id"

    [[ "$installation_id" =~ ^[0-9]+$ ]] ||
        die "Invalid Installation ID: $installation_id"

    # Normalize tilde expansion and quotes
    pem_input="${pem_input%\"}"
    pem_input="${pem_input#\"}"
    pem_input="${pem_input%\'}"
    pem_input="${pem_input#\'}"
    if [[ "$pem_input" == "~/"* ]]; then
        pem_input="$HOME/${pem_input:2}"
    elif [[ "$pem_input" == "~" ]]; then
        pem_input="$HOME"
    fi

    if [[ -f "$pem_input" ]]; then
        if [[ "$(realpath "$pem_input")" != "$(realpath "$PEM_FILE")" ]]; then
            cp "$pem_input" "$PEM_FILE"
        fi
    elif echo "$pem_input" | grep -q "BEGIN .*PRIVATE KEY"; then
        printf '%s\n' "$pem_input" > "$PEM_FILE"
    else
        die "PEM file or private key content invalid or not found."
    fi

    chmod 600 "$PEM_FILE"

    grep -q "BEGIN .*PRIVATE KEY" "$PEM_FILE" ||
        die "Invalid PEM private key: missing BEGIN line."

    grep -q "END .*PRIVATE KEY" "$PEM_FILE" ||
        die "Invalid PEM private key: missing END line."

    set_env GITHUB_APP_ID "$app_id"
    set_env GITHUB_INSTALLATION_ID "$installation_id"

    echo "Configuring GitHub broker service and permissions..."
    github_ensure_service

    echo "Starting GitHub broker..."
    github_start_broker

    # Poll up to 5s for socket readiness
    local ready=0
    for _ in {1..25}; do
        if [[ -S "$BROKER_SOCKET" ]]; then
            ready=1
            break
        fi
        sleep 0.2
    done

    if [[ $ready -eq 0 ]]; then
        die "Broker socket was not created at $BROKER_SOCKET. Check: $BROKER_DIR/broker.log or journalctl -u $SERVICE_NAME -n 30 --no-pager"
    fi

    echo "✓ Broker running"
    echo "✓ Socket ready"
    echo
    echo "GitHub setup infrastructure completed."
    echo
    echo "Next:"
    echo "  aiws github test"
    echo
}

github_status() {
    [[ -f "$ENV_FILE" ]] &&
        source "$ENV_FILE" || true

    echo; print_header "GITHUB INTEGRATION"
    echo
    echo "App ID:          ${GITHUB_APP_ID:-not configured}"
    echo "Installation ID: ${GITHUB_INSTALLATION_ID:-not configured}"

    [[ -f "$PEM_FILE" ]] &&
        echo "Private key:     configured" ||
        echo "Private key:     not configured"

    [[ -S "$BROKER_SOCKET" ]] &&
        echo "Broker socket:   ready" ||
        echo "Broker socket:   not ready"

    local svc_active="stopped"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        svc_active="running (systemd)"
    elif [[ -f "$BROKER_DIR/broker.pid" ]] && kill -0 "$(cat "$BROKER_DIR/broker.pid" 2>/dev/null)" 2>/dev/null; then
        svc_active="running (background)"
    fi
    echo "Broker service:  $svc_active"

    echo
}

github_test() {
    [[ -f "$ENV_FILE" ]] &&
        source "$ENV_FILE" || true

    [[ -n "${GITHUB_APP_ID:-}" ]] ||
        die "GitHub App is not configured."

    [[ -n "${GITHUB_INSTALLATION_ID:-}" ]] ||
        die "GitHub Installation is not configured."

    [[ -f "$PEM_FILE" ]] ||
        die "Private key is missing."

    # Self-healing socket recovery: if service is not running or socket missing, attempt startup
    if [[ ! -S "$BROKER_SOCKET" ]]; then
        echo "Broker socket not active, attempting service startup..."
        github_ensure_service >/dev/null 2>&1 || true
        github_start_broker
        for _ in {1..15}; do
            if [[ -S "$BROKER_SOCKET" ]]; then
                break
            fi
            sleep 0.2
        done
    fi

    if [[ ! -S "$BROKER_SOCKET" ]]; then
        die "Broker socket is not ready at $BROKER_SOCKET. Check: $BROKER_DIR/broker.log or journalctl -u $SERVICE_NAME -n 30 --no-pager"
    fi

    echo "Testing GitHub App credentials..."

    local py_bin="$ROOT/.venv/bin/python"
    [[ -x "$py_bin" ]] || py_bin="$(command -v python3)"

    "$py_bin" - <<PY
import sys
sys.path.insert(0, "$ROOT/broker")

import github_broker

token = github_broker.get_installation_token()

if not token:
    raise SystemExit("GitHub did not return a token.")

print("✓ GitHub Installation Token: OK")
PY

    echo
    echo "GitHub authentication: READY ✓"
}

case "${1:-}" in
    setup)
        shift
        github_setup "$@"
        ;;
    ensure-service)
        github_ensure_service
        ;;
    status)
        github_status
        ;;
    test)
        github_test
        ;;
    *)
        echo "Usage: github.sh {setup [app_id] [inst_id] [pem]|ensure-service|status|test}"
        exit 1
        ;;
esac
