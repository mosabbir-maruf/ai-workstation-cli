#!/usr/bin/env bash
set -euo pipefail

ROOT="${AI_WORKSTATION_ROOT:-$HOME/ai-workstation}"
ENV_FILE="$ROOT/.env"
SECRETS_DIR="$ROOT/secrets"
RUNTIME_DIR="$ROOT/runtime"
TUNNEL_DIR="$RUNTIME_DIR/cloudflared"
CONFIG_FILE="$TUNNEL_DIR/config.yml"
SERVICE_NAME="ai-cloudflared"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTS_SCRIPT="$LIB_DIR/ports.sh"

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

load_env_quiet() {
    [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || true
}

valid_port() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 && "$1" -le 65535 ]]
}

valid_hostname() {
    [[ "${1:-}" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

ensure_cloudflared() {
    if command -v cloudflared >/dev/null 2>&1; then
        return 0
    fi

    echo "cloudflared not found. Installing..."

    local arch deb
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

    case "$arch" in
        amd64|x86_64) deb="cloudflared-linux-amd64.deb" ;;
        arm64|aarch64) deb="cloudflared-linux-arm64.deb" ;;
        *) die "Unsupported architecture for cloudflared auto-install: $arch" ;;
    esac

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    curl -fsSL -o "$tmp/$deb" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/$deb"
    sudo dpkg -i "$tmp/$deb" || sudo apt-get install -f -y

    command -v cloudflared >/dev/null 2>&1 ||
        die "cloudflared installation failed."

    echo "✓ cloudflared installed: $(cloudflared --version 2>&1 | head -1)"
}

detect_app_port() {
    # First port from the shared detector (already sorted). No extra
    # container exec when the caller passes an explicit port to sync.
    [[ -f "$PORTS_SCRIPT" ]] || return 1

    local all_ports
    all_ports="$(bash "$PORTS_SCRIPT" || true)"
    [[ -n "$all_ports" ]] || return 1

    printf '%s\n' "${all_ports%% *}"
}

write_config() {
    local tunnel_id="$1"
    local creds_file="$2"
    local app_host="$3"
    local dsh_host="$4"
    local app_port="$5"

    mkdir -p "$TUNNEL_DIR"
    chmod 700 "$TUNNEL_DIR"

    cat > "$CONFIG_FILE" <<EOF
# Managed by: ai tunnel setup / ai tunnel sync
# Do not edit manually.
tunnel: $tunnel_id
credentials-file: $creds_file
protocol: quic
edge-ip-version: auto
retries: 5
originRequest:
  connectTimeout: 10s
ingress:
  - hostname: $app_host
    service: http://127.0.0.1:$app_port
  - hostname: $dsh_host
    service: http://127.0.0.1:4090
  - service: http_status:404
EOF

    chmod 600 "$CONFIG_FILE"
}

tunnel_setup() {
    echo
    echo "========================================"
    echo "     Cloudflare Tunnel Setup"
    echo "========================================"
    echo
    echo "Prerequisites (one time, on your admin machine):"
    echo "  1. Domain added to Cloudflare (DNS)."
    echo "  2. cloudflared tunnel login"
    echo "  3. cloudflared tunnel create <name>"
    echo "  4. cloudflared tunnel route dns <name> <app-host>"
    echo "  5. cloudflared tunnel route dns <name> <dsh-host>"
    echo "  6. Cloudflare Access policy on both hostnames."
    echo

    ensure_cloudflared

    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"

    local tunnel_id creds_src app_host dsh_host app_port detected

    read -r -p "Tunnel ID: " tunnel_id
    [[ "$tunnel_id" =~ ^[a-f0-9-]{10,}$ ]] ||
        die "Invalid Tunnel ID (expected UUID from 'cloudflared tunnel list')."

    echo
    read -r -p "Tunnel credentials JSON path: " creds_src
    # tolerate surrounding quotes from copy-paste
    creds_src="${creds_src%\"}"
    creds_src="${creds_src#\"}"
    creds_src="${creds_src%\'}"
    creds_src="${creds_src#\'}"
    [[ -f "$creds_src" ]] ||
        die "Credentials file not found: $creds_src"

    local creds_dest="$SECRETS_DIR/cloudflared-$tunnel_id.json"
    if [[ "$(realpath "$creds_src")" != "$(realpath "$creds_dest" 2>/dev/null || echo "$creds_dest")" ]]; then
        cp "$creds_src" "$creds_dest"
    fi
    chmod 600 "$creds_dest"

    echo
    read -r -p "App hostname (e.g. app.example.com): " app_host
    valid_hostname "$app_host" ||
        die "Invalid hostname: $app_host"

    read -r -p "DSH hostname (e.g. dsh.example.com): " dsh_host
    valid_hostname "$dsh_host" ||
        die "Invalid hostname: $dsh_host"

    [[ "$app_host" != "$dsh_host" ]] ||
        die "App and DSH hostnames must differ."

    detected="$(detect_app_port || true)"
    if [[ -n "$detected" ]]; then
        echo
        echo "Detected app port: $detected"
    fi

    echo
    read -r -p "App local port [${detected:-3000}]: " app_port
    app_port="${app_port:-${detected:-3000}}"
    valid_port "$app_port" ||
        die "Invalid port: $app_port"

    write_config "$tunnel_id" "$creds_dest" "$app_host" "$dsh_host" "$app_port"

    set_env CLOUDFLARED_TUNNEL_ID "$tunnel_id"
    set_env CLOUDFLARED_APP_HOSTNAME "$app_host"
    set_env CLOUDFLARED_DSH_HOSTNAME "$dsh_host"
    set_env CLOUDFLARED_APP_PORT "$app_port"

    echo
    echo "✓ Tunnel config written: $CONFIG_FILE"

    echo
    echo "Creating systemd service..."

    local cloudflared_bin
    cloudflared_bin="$(command -v cloudflared)" ||
        die "cloudflared not found after install."

    sudo tee "$SERVICE_FILE" >/dev/null <<SERVICE
[Unit]
Description=AI Workstation Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
ExecStart=$cloudflared_bin tunnel --config $CONFIG_FILE run
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME" >/dev/null
    sudo systemctl restart "$SERVICE_NAME"

    sleep 2

    sudo systemctl is-active --quiet "$SERVICE_NAME" ||
        die "cloudflared failed to start. Run: sudo journalctl -u $SERVICE_NAME -n 50"

    echo "✓ Tunnel running"
    echo
    echo "URLs (after DNS + Access policy propagate):"
    echo "  App : https://$app_host"
    echo "  DSH : https://$dsh_host"
    echo
    echo "If your dev server rejects the hostname (e.g. Vite 403),"
    echo "allow it: Vite server.allowedHosts, Next.js experimental"
    echo "allowedDevOrigins, or equivalent."
    echo
}

tunnel_sync() {
    load_env_quiet

    local app_port="${1:-}"
    local tunnel_id="${CLOUDFLARED_TUNNEL_ID:-}"
    local app_host="${CLOUDFLARED_APP_HOSTNAME:-}"
    local dsh_host="${CLOUDFLARED_DSH_HOSTNAME:-}"
    local creds_dest="$SECRETS_DIR/cloudflared-$tunnel_id.json"

    [[ -n "$tunnel_id" && -n "$app_host" && -n "$dsh_host" ]] ||
        die "Tunnel is not configured. Run: ai tunnel setup"

    if [[ -z "$app_port" ]]; then
        app_port="$(detect_app_port || true)"
        [[ -n "$app_port" ]] ||
            die "No app port detected. Usage: ai tunnel sync <port>"
        echo "Detected app port: $app_port"
    fi

    valid_port "$app_port" ||
        die "Invalid port: $app_port"

    [[ -f "$creds_dest" ]] ||
        die "Credentials file missing: $creds_dest"

    # No-op when already in sync: avoids a needless service restart.
    if [[ "${CLOUDFLARED_APP_PORT:-}" == "$app_port" && -f "$CONFIG_FILE" ]]; then
        echo "✓ Tunnel already in sync (port $app_port)"
        echo "  App : https://$app_host -> 127.0.0.1:$app_port"
        return 0
    fi

    write_config "$tunnel_id" "$creds_dest" "$app_host" "$dsh_host" "$app_port"
    set_env CLOUDFLARED_APP_PORT "$app_port"

    if sudo systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        sudo systemctl restart "$SERVICE_NAME"
        sleep 2
        sudo systemctl is-active --quiet "$SERVICE_NAME" ||
            die "cloudflared failed to restart."
        echo "✓ Tunnel synced to port $app_port and restarted"
    else
        echo "✓ Tunnel config synced to port $app_port (service not running)"
    fi

    echo "  App : https://$app_host -> 127.0.0.1:$app_port"
}

tunnel_status() {
    load_env_quiet

    echo "=== Cloudflare Tunnel ==="
    echo
    echo "Tunnel ID:     ${CLOUDFLARED_TUNNEL_ID:-not configured}"
    echo "App hostname:  ${CLOUDFLARED_APP_HOSTNAME:-not configured}"
    echo "DSH hostname:  ${CLOUDFLARED_DSH_HOSTNAME:-not configured}"
    echo "App port:      ${CLOUDFLARED_APP_PORT:-not configured}"
    echo

    [[ -f "$CONFIG_FILE" ]] &&
        echo "Config:        configured" ||
        echo "Config:        not configured"

    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null &&
        echo "Service:       running" ||
        echo "Service:       stopped"
    echo
}

case "${1:-}" in
    setup)
        tunnel_setup
        ;;
    sync)
        tunnel_sync "${2:-}"
        ;;
    status)
        tunnel_status
        ;;
    start)
        sudo systemctl start "$SERVICE_NAME"
        ;;
    stop)
        sudo systemctl stop "$SERVICE_NAME"
        ;;
    logs)
        sudo journalctl -u "$SERVICE_NAME" -n 100 -f
        ;;
    *)
        echo "Usage: tunnel.sh {setup|sync [port]|status|start|stop|logs}"
        exit 1
        ;;
esac
