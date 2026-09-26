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

github_setup() {
    echo
    echo "========================================"
    echo "        GitHub App Setup"
    echo "========================================"
    echo

    [[ -f "$BROKER_SCRIPT" ]] ||
        die "GitHub broker not found."

    [[ -f "$ROOT/docker/compose.yml" ]] ||
        die "Docker Compose file not found."

    mkdir -p "$SECRETS_DIR" "$BROKER_DIR"
    chmod 700 "$SECRETS_DIR" "$BROKER_DIR"

    local app_id installation_id pem_path

    read -r -p "GitHub App ID: " app_id
    [[ "$app_id" =~ ^[0-9]+$ ]] ||
        die "Invalid App ID."

    read -r -p "GitHub Installation ID: " installation_id
    [[ "$installation_id" =~ ^[0-9]+$ ]] ||
        die "Invalid Installation ID."

    echo
    read -r -p "Private key (.pem) path: " pem_path

    # `read` does not perform tilde expansion, so expand a leading ~/ manually.
    # Also tolerate surrounding quotes from copy-paste.
    pem_path="${pem_path%\"}"
    pem_path="${pem_path#\"}"
    pem_path="${pem_path%\'}"
    pem_path="${pem_path#\'}"
    if [[ "$pem_path" == "~/"* ]]; then
        pem_path="$HOME/${pem_path:2}"
    elif [[ "$pem_path" == "~" ]]; then
        pem_path="$HOME"
    fi

    [[ -f "$pem_path" ]] ||
        die "PEM file not found: $pem_path"

    if [[ "$(realpath "$pem_path")" != "$(realpath "$PEM_FILE")" ]]; then
        cp "$pem_path" "$PEM_FILE"
    fi

    chmod 600 "$PEM_FILE"

    grep -q "BEGIN .*PRIVATE KEY" "$PEM_FILE" ||
        die "Invalid PEM private key."

    grep -q "END .*PRIVATE KEY" "$PEM_FILE" ||
        die "Invalid PEM private key."

    set_env GITHUB_APP_ID "$app_id"
    set_env GITHUB_INSTALLATION_ID "$installation_id"
    set_env GITHUB_BROKER_SOCKET "$BROKER_SOCKET"

    echo
    echo "✓ Credentials saved"

    if ! getent group ai-broker >/dev/null 2>&1; then
        sudo groupadd --system ai-broker
    fi

    local broker_gid
    broker_gid="$(getent group ai-broker | cut -d: -f3)"

    set_env GITHUB_BROKER_GID "$broker_gid"

    sudo usermod -aG ai-broker "$(id -un)"

    sudo chown -R "$(id -un)":ai-broker "$BROKER_DIR"
    sudo chmod 770 "$BROKER_DIR"

    echo "✓ Broker group configured"
    echo "✓ Broker GID: $broker_gid"

    echo
    echo "Configuring GitHub broker..."

    sudo tee "$SERVICE_FILE" >/dev/null <<SERVICE
[Unit]
Description=AI Workstation GitHub App Credential Broker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
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

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME" >/dev/null
    sudo systemctl restart "$SERVICE_NAME"

    sleep 1

    sudo systemctl is-active --quiet "$SERVICE_NAME" ||
        die "GitHub broker failed to start."

    [[ -S "$BROKER_SOCKET" ]] ||
        die "Broker socket was not created."

    echo "✓ Broker running"
    echo "✓ Socket ready"

    echo
    echo "Installing credential helper..."

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

    echo "✓ Credential helper created"

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

    [[ -S "$BROKER_SOCKET" ]] ||
        die "Broker socket is not ready."

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
        github_setup
        ;;
    status)
        github_status
        ;;
    test)
        github_test
        ;;
    *)
        echo "Usage: github.sh {setup|status|test}"
        exit 1
        ;;
esac
