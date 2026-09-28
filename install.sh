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
ROOT="$(cd "$(dirname "$RESOLVED_SOURCE")" && pwd)"
ENV_FILE="$ROOT/.env"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

echo
cat <<'BANNER'
╭──────────────────────────────────────────────────────────────────╮
│   █████╗ ██╗██╗    ██╗███████╗     ██████╗██╗     ██╗            │
│  ██╔══██╗██║██║    ██║██╔════╝    ██╔════╝██║     ██║            │
│  ███████║██║██║ █╗ ██║███████╗    ██║     ██║     ██║            │
│  ██╔══██║██║██║███╗██║╚════██║    ██║     ██║     ██║            │
│  ██║  ██║██║╚███╔███╔╝███████║    ╚██████╗███████╗██║            │
│  ╚═╝  ╚═╝╚═╝ ╚══╝╚══╝ ╚══════╝     ╚═════╝╚══════╝╚═╝            │
│  AIWS CLI Installer · Host Daemon, Broker & Container Runtime    │
╰──────────────────────────────────────────────────────────────────╯
BANNER
echo

# --------------------------------------------------
# Basic requirements
# --------------------------------------------------

command -v sudo >/dev/null 2>&1 ||
    die "sudo is required."

command -v docker >/dev/null 2>&1 ||
    die "Docker is required. Install Docker first."

docker info >/dev/null 2>&1 ||
    die "Docker daemon is not accessible."

command -v git >/dev/null 2>&1 ||
    die "Git is required."

command -v python3 >/dev/null 2>&1 ||
    die "Python 3 is required."

# --------------------------------------------------
# Required Python venv support
# --------------------------------------------------
# NOTE: `python3 -m venv --help` can succeed on Debian/Ubuntu even when
# ensurepip/pip is missing, producing a venv with "No module named pip".
# Test the real functionality instead.
if ! python3 -c 'import venv, ensurepip' >/dev/null 2>&1; then
    echo "Installing Python venv support..."
    PYVER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    sudo apt-get update
    # Versioned package first (e.g. python3.12-venv on Ubuntu 24.04),
    # then fall back to the generic metapackage.
    sudo apt-get install -y "python${PYVER}-venv" 2>/dev/null \
        || sudo apt-get install -y python3-venv
fi

python3 -c 'import venv, ensurepip' >/dev/null 2>&1 ||
    die "Python venv/ensurepip is still unavailable. Install it manually, e.g.: sudo apt-get install -y python3-venv python3-pip"

# --------------------------------------------------
# Sudoers & journal permissions for daemon & CLI
# --------------------------------------------------
echo "Configuring sudoers permissions..."
SUDOERS_FILE="/etc/sudoers.d/ai-workstation"
echo "$(id -un) ALL=(ALL) NOPASSWD: ALL" | sudo tee "$SUDOERS_FILE" >/dev/null
sudo chmod 0440 "$SUDOERS_FILE"
sudo usermod -aG systemd-journal "$(id -un)" 2>/dev/null || true
echo "✓ Sudoers permissions configured"

# --------------------------------------------------
# Directory structure
# --------------------------------------------------

echo "Creating directories..."

mkdir -p \
    "$ROOT/runtime/dsh" \
    "$ROOT/runtime/app" \
    "$ROOT/runtime/npm-global" \
    "$ROOT/runtime/github-broker" \
    "$ROOT/secrets" \
    "$HOME/projects"

chmod 700 \
    "$ROOT/runtime" \
    "$ROOT/runtime/dsh" \
    "$ROOT/runtime/app" \
    "$ROOT/runtime/npm-global" \
    "$ROOT/runtime/github-broker" \
    "$ROOT/secrets"

# --------------------------------------------------
# Environment
# --------------------------------------------------

if [[ ! -f "$ENV_FILE" ]]; then
    [[ -f "$ROOT/.env.example" ]] ||
        die ".env.example not found."

    cp "$ROOT/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    echo "✓ Created .env"
else
    echo "✓ .env already exists"
fi

# --------------------------------------------------
# Python virtual environment
# --------------------------------------------------

# Recreate a broken venv from a previous partial run (exists but has no pip).
if [[ -x "$ROOT/.venv/bin/python" ]]; then
    if ! "$ROOT/.venv/bin/python" -m pip --version >/dev/null 2>&1; then
        echo "Existing .venv has no pip — recreating..."
        rm -rf "$ROOT/.venv"
    else
        echo "✓ Python virtual environment already exists"
    fi
fi

if [[ ! -x "$ROOT/.venv/bin/python" ]]; then
    echo "Creating Python virtual environment..."

    rm -rf "$ROOT/.venv"
    python3 -m venv "$ROOT/.venv"

    # Some minimal images still produce a venv without pip; repair it.
    if ! "$ROOT/.venv/bin/python" -m pip --version >/dev/null 2>&1; then
        echo "Bootstrapping pip with ensurepip..."
        "$ROOT/.venv/bin/python" -m ensurepip --upgrade
    fi

    "$ROOT/.venv/bin/python" -m pip --version >/dev/null 2>&1 ||
        die "pip is unavailable in .venv even after ensurepip. Run: rm -rf \"$ROOT/.venv\"; sudo apt-get install -y python3-venv python3-pip; ./install.sh"

    echo "✓ Python virtual environment created"
fi

# --------------------------------------------------
# Python dependencies
# --------------------------------------------------

echo "Checking Python dependencies..."

"$ROOT/.venv/bin/python" -m pip install \
    --disable-pip-version-check \
    --quiet \
    --upgrade \
    pip

"$ROOT/.venv/bin/python" -m pip install \
    --disable-pip-version-check \
    --quiet \
    "PyJWT[crypto]"

echo "✓ PyJWT ready"

# --------------------------------------------------
# Install AI CLI & Daemon
# --------------------------------------------------

echo "Installing ai CLI..."

sudo ln -sfn     "$ROOT/scripts/ai"     /usr/local/bin/ai

sudo chmod 0755 "$ROOT/scripts/ai"
chmod 0755 "$ROOT/daemon/server.py"

echo "✓ ai CLI installed"

# Configure Host Daemon Systemd Service
DAEMON_SERVICE_FILE="/etc/systemd/system/ai-workstation-daemon.service"
echo "Configuring AI Workstation daemon service..."

CURRENT_USER="${SUDO_USER:-$(id -un)}"
if [[ "$CURRENT_USER" == "root" && -n "${SUDO_USER:-}" ]]; then
    CURRENT_USER="$SUDO_USER"
fi
if [[ "$CURRENT_USER" == "root" ]]; then
    ROOT_OWNER="$(stat -c '%U' "$ROOT" 2>/dev/null || stat -f '%Su' "$ROOT" 2>/dev/null || echo "")"
    if [[ -n "$ROOT_OWNER" && "$ROOT_OWNER" != "root" ]]; then
        CURRENT_USER="$ROOT_OWNER"
    fi
fi

sudo tee "$DAEMON_SERVICE_FILE" >/dev/null <<SERVICE
[Unit]
Description=AI Workstation Host Control Daemon
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$ROOT
Environment=AI_WORKSTATION_ROOT=$ROOT
ExecStart=/usr/bin/python3 $ROOT/daemon/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload 2>/dev/null || true
sudo systemctl enable ai-workstation-daemon 2>/dev/null || true
sudo systemctl restart ai-workstation-daemon 2>/dev/null || true

echo "✓ Host daemon service configured"

# Configure GitHub Broker Systemd Service & Permissions
echo "Configuring GitHub Broker service..."
bash "$ROOT/scripts/lib/github.sh" ensure-service || true
echo "✓ GitHub broker service configured"

# --------------------------------------------------
# Validation
# --------------------------------------------------

echo
echo "Running validation..."

[[ -x /usr/local/bin/ai ]] ||
    die "ai CLI installation failed."

[[ -x "$ROOT/.venv/bin/python" ]] ||
    die "Python virtual environment is unavailable."

"$ROOT/.venv/bin/python" -c 'import jwt' >/dev/null ||
    die "PyJWT installation failed."

"$ROOT/.venv/bin/python" -c 'from jwt.api_jws import PyJWS; PyJWS().get_algorithm_by_name("RS256")' >/dev/null ||
    die "PyJWT cryptography backend (RS256) is unavailable. Run: .venv/bin/pip install 'PyJWT[crypto]'"

[[ -d "$ROOT/runtime/dsh" ]] ||
    die "runtime/dsh missing."

[[ -d "$ROOT/runtime/app" ]] ||
    die "runtime/app missing."

[[ -d "$ROOT/runtime/npm-global" ]] ||
    die "runtime/npm-global missing."

[[ -d "$ROOT/runtime/github-broker" ]] ||
    die "runtime/github-broker missing."

[[ -d "$ROOT/secrets" ]] ||
    die "secrets directory missing."

echo
echo "╭──────────────────────────────────────────────────────────────────╮"
echo "│  ✓ AIWS CLI Core System Installed Successfully                   │"
echo "╰──────────────────────────────────────────────────────────────────╯"
echo

if [[ -t 0 && -t 1 && "${AIWS_SKIP_SETUP:-0}" != "1" ]]; then
    read -r -p "Launch interactive AIWS CLI Setup Flow now? [Y/s (skip)] (default: Y): " _launch_setup || true
    if [[ -z "${_launch_setup:-}" || "${_launch_setup}" =~ ^[Yy]$ ]]; then
        exec "$ROOT/scripts/ai" setup
    fi
fi

echo "Skipped interactive setup flow. You can launch it anytime by running:"
echo
echo "  ai setup"
echo
echo "Or configure individual components manually:"
echo "  1. ai doctor          # Verify host environment"
echo "  2. ai github setup    # Configure GitHub App integration (optional)"
echo "  3. ai tunnel setup    # Configure Cloudflare Tunnel (optional)"
echo "  4. ai add <repo-url>  # Clone a project into ~/projects"
echo "  5. ai use <project>   # Activate project"
echo "  6. ai start           # Start container & DSH agent runtime"
echo
