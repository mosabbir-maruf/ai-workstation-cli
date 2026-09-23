#!/usr/bin/env bash
# Anywhere access via a dashboard-managed Cloudflare Tunnel.
#
# The tunnel itself is created in Cloudflare Zero Trust -> Networks ->
# Tunnels (Cloudflared type). This script only installs the connector on
# the VPS with the dashboard token and remembers the hostnames so
# `ai preview` can print the public URLs and flag a stale app port.
set -euo pipefail

ROOT="${AI_WORKSTATION_ROOT:-$HOME/ai-workstation}"
ENV_FILE="$ROOT/.env"
SECRETS_DIR="$ROOT/secrets"
TOKEN_FILE="$SECRETS_DIR/cloudflared-token"
SERVICE_NAME="cloudflared"
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
    # First port from the shared detector (already sorted).
    [[ -f "$PORTS_SCRIPT" ]] || return 1

    local all_ports
    all_ports="$(bash "$PORTS_SCRIPT" || true)"
    [[ -n "$all_ports" ]] || return 1

    printf '%s\n' "${all_ports%% *}"
}

tunnel_setup() {
    echo
    echo "========================================"
    echo "     Cloudflare Tunnel Setup"
    echo "========================================"
    echo
    echo "First, in Cloudflare Zero Trust -> Networks -> Tunnels:"
    echo "  1. Create tunnel (type Cloudflared), name it, copy its token."
    echo "  2. Add public hostnames AFTER setup (see below)."
    echo "  3. Add an Access policy for both hostnames."
    echo

    ensure_cloudflared

    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"

    local token app_host dsh_host app_port detected

    read -r -s -p "Connector token (from dashboard, input hidden): " token
    echo
    [[ -n "$token" ]] ||
        die "Empty token. Copy it from the tunnel's connector install command."

    printf '%s' "$token" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    token=""

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
    [[ -n "$detected" ]] &&
        echo "Detected app port: $detected"

    echo
    read -r -p "App local port [${detected:-3000}]: " app_port
    app_port="${app_port:-${detected:-3000}}"
    valid_port "$app_port" ||
        die "Invalid port: $app_port"

    echo
    echo "Installing connector service..."

    if sudo systemctl list-unit-files --quiet "$SERVICE_NAME.service" 2>/dev/null ||
        [[ -f "/etc/systemd/system/$SERVICE_NAME.service" ]]; then
        sudo systemctl restart "$SERVICE_NAME"
    else
        sudo cloudflared service install "$(cat "$TOKEN_FILE")"
    fi

    sleep 2

    sudo systemctl is-active --quiet "$SERVICE_NAME" ||
        die "cloudflared connector failed to start. Run: sudo journalctl -u $SERVICE_NAME -n 50"

    set_env CLOUDFLARED_TOKEN_SET "1"
    set_env CLOUDFLARED_APP_HOSTNAME "$app_host"
    set_env CLOUDFLARED_DSH_HOSTNAME "$dsh_host"
    set_env CLOUDFLARED_APP_PORT "$app_port"
    set_env DSH_TRUSTED_HOSTS "$dsh_host"
    if [[ -z "$(grep '^ALLOWED_HOSTS=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)" ]]; then
        set_env ALLOWED_HOSTS "$app_host"
    else
        echo "NOTE: ALLOWED_HOSTS already set; append '$app_host' to it (comma-separated) if this hostname is new."
    fi

    echo "✓ Connector running"
    echo
    echo "Now add both public hostnames in the dashboard tunnel (origin = VPS):"
    echo "  $app_host -> http://127.0.0.1:$app_port"
    echo "  $dsh_host -> http://127.0.0.1:4090"
    echo
    echo "URLs (after DNS + Access policy propagate):"
    echo "  App : https://$app_host"
    echo "  DSH : https://$dsh_host"
    echo
}

tunnel_sync() {
    load_env_quiet

    local app_port="${1:-}"
    local app_host="${CLOUDFLARED_APP_HOSTNAME:-}"
    local dsh_host="${CLOUDFLARED_DSH_HOSTNAME:-}"

    [[ -n "$app_host" && -n "$dsh_host" ]] ||
        die "Tunnel is not configured. Run: ai tunnel setup"

    if [[ -z "$app_port" ]]; then
        app_port="$(detect_app_port || true)"
        [[ -n "$app_port" ]] ||
            die "No app port detected. Usage: ai tunnel sync <port>"
        echo "Detected app port: $app_port"
    fi

    valid_port "$app_port" ||
        die "Invalid port: $app_port"

    # Ingress lives in the dashboard: only the remembered port can be
    # updated here. Changing it takes one click in the tunnel's public
    # hostnames; nothing restarts, so this is instant.
    if [[ "${CLOUDFLARED_APP_PORT:-}" == "$app_port" ]]; then
        echo "✓ Tunnel in sync (port $app_port)"
        echo "  App : https://$app_host -> 127.0.0.1:$app_port"
        return 0
    fi

    set_env CLOUDFLARED_APP_PORT "$app_port"

    echo "App port changed: ${CLOUDFLARED_APP_PORT:-none} -> $app_port"
    echo "Update it in Zero Trust -> Tunnels -> <tunnel> -> Public hostnames:"
    echo "  $app_host -> http://127.0.0.1:$app_port"
    echo "  App : https://$app_host"
}

tunnel_status() {
    load_env_quiet

    echo "=== Cloudflare Tunnel ==="
    echo
    [[ -f "$TOKEN_FILE" ]] &&
        echo "Connector token: configured" ||
        echo "Connector token: not configured"
    echo "App hostname:  ${CLOUDFLARED_APP_HOSTNAME:-not configured}"
    echo "DSH hostname:  ${CLOUDFLARED_DSH_HOSTNAME:-not configured}"
    echo "App port:      ${CLOUDFLARED_APP_PORT:-not configured}"
    echo

    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null &&
        echo "Connector:     running" ||
        echo "Connector:     stopped"
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
