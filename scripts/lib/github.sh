#!/usr/bin/env bash
set -euo pipefail

ROOT="${AI_WORKSTATION_ROOT:-$HOME/ai-workstation-cli}"
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
    current_user="$(id -un)"

    if ! getent group ai-broker >/dev/null 2>&1; then
        sudo groupadd --system ai-broker
    fi

    local broker_gid
    broker_gid="$(getent group ai-broker | cut -d: -f3)"

    set_env GITHUB_BROKER_GID "$broker_gid"
    set_env GITHUB_BROKER_SOCKET "$BROKER_SOCKET"

    if ! id -nG "$current_user" | grep -qw "ai-broker"; then
        sudo usermod -aG ai-broker "$current_user"
    fi

    mkdir -p "$SECRETS_DIR" "$BROKER_DIR"
    chmod 700 "$SECRETS_DIR"
    sudo chown -R "$current_user":ai-broker "$BROKER_DIR"
    sudo chmod 770 "$BROKER_DIR"

    sudo tee "$SERVICE_FILE" >/dev/null <<SERVICE
[Unit]
Description=AI Workstation GitHub App Credential Broker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$current_user
Group=ai-broker

WorkingDirectory=$ROOT

Environment=AI_WORKSTATION_ROOT=$ROOT

ExecStart=$ROOT/.venv/bin/python $BROKER_SCRIPT

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

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

github_setup() {
    local app_id="${1:-}"
    local installation_id="${2:-}"
    local pem_input="${3:-}"

    [[ -f "$BROKER_SCRIPT" ]] ||
        die "GitHub broker not found."

    [[ -f "$ROOT/docker/compose.yml" ]] ||
        die "Docker Compose file not found."

    mkdir -p "$SECRETS_DIR" "$BROKER_DIR"
    chmod 700 "$SECRETS_DIR" "$BROKER_DIR"

    if [[ -z "$app_id" || -z "$installation_id" || -z "$pem_input" ]]; then
        echo
        echo "========================================"
        echo "        GitHub App Setup"
        echo "========================================"
        echo

        read -r -p "GitHub App ID: " app_id
        [[ "$app_id" =~ ^[0-9]+$ ]] ||
            die "Invalid App ID."

        read -r -p "GitHub Installation ID: " installation_id
        [[ "$installation_id" =~ ^[0-9]+$ ]] ||
            die "Invalid Installation ID."

        echo
        read -r -p "Private key (.pem) path: " pem_input
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
    sudo systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl restart "$SERVICE_NAME"

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
        if ! sudo systemctl is-active --quiet "$SERVICE_NAME"; then
            die "GitHub broker failed to start: $(sudo systemctl status "$SERVICE_NAME" 2>&1 | grep -E "Active:|Failed|Error" | head -n 2 | sed 's/^[ \t]*//')"
        fi
        die "Broker socket was not created at $BROKER_SOCKET."
    fi

    echo "✓ Broker running"
    echo "✓ Socket ready"
    echo
    echo "GitHub setup infrastructure completed."
    echo
    echo "Next:"
    echo "  ai github test"
    echo
}

github_status() {
    [[ -f "$ENV_FILE" ]] &&
        source "$ENV_FILE" || true

    echo "=== GitHub Integration ==="
    echo
    echo "App ID:          ${GITHUB_APP_ID:-not configured}"
    echo "Installation ID: ${GITHUB_INSTALLATION_ID:-not configured}"

    [[ -f "$PEM_FILE" ]] &&
        echo "Private key:     configured" ||
        echo "Private key:     not configured"

    [[ -S "$BROKER_SOCKET" ]] &&
        echo "Broker socket:   ready" ||
        echo "Broker socket:   not ready"

    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null &&
        echo "Broker service:  running" ||
        echo "Broker service:  stopped"

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
        sudo systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
        sudo systemctl restart "$SERVICE_NAME" 2>/dev/null || true
        for _ in {1..15}; do
            if [[ -S "$BROKER_SOCKET" ]]; then
                break
            fi
            sleep 0.2
        done
    fi

    if [[ ! -S "$BROKER_SOCKET" ]]; then
        local svc_status
        svc_status="$(sudo systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown")"
        if [[ "$svc_status" != "active" ]]; then
            die "Broker socket is not ready ($SERVICE_NAME is $svc_status). Check: sudo journalctl -u $SERVICE_NAME -n 30 --no-pager"
        else
            die "Broker socket is not ready at $BROKER_SOCKET even though $SERVICE_NAME is active. Check directory permissions."
        fi
    fi

    echo "Testing GitHub App credentials..."

    "$ROOT/.venv/bin/python" - <<PY
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
