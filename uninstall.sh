#!/usr/bin/env bash
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================================="
echo "                 AIWS Uninstallation                      "
echo "=========================================================="
echo "This will completely remove AIWS, including:"
echo "  - Background services (aiws-daemon, github-broker)"
echo "  - Docker containers, networks, and images (aiws-*)"
echo "  - Global CLI symlinks (/usr/local/bin/aiws)"
echo "  - All runtime state, logs, and secrets in $ROOT"
echo

if [[ "$1" != "--yes" && "$1" != "-y" ]]; then
    read -r -p "Are you sure you want to proceed? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Uninstallation cancelled."; exit 0; }
fi

echo
echo "1/5 Stopping active workloads..."
if command -v docker >/dev/null 2>&1; then
    if [[ -f "$ROOT/docker/compose.yml" ]]; then
        export AIWS_ROOT="$ROOT"
        docker compose -f "$ROOT/docker/compose.yml" down -v --remove-orphans 2>/dev/null || true
    fi
fi

echo "2/5 Removing background services..."
if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop aiws-daemon github-broker 2>/dev/null || true
    sudo systemctl disable aiws-daemon github-broker 2>/dev/null || true
    sudo rm -f /etc/systemd/system/aiws-daemon.service
    sudo rm -f /etc/systemd/system/github-broker.service
    sudo systemctl daemon-reload 2>/dev/null || true
fi

echo "3/5 Removing global CLI command..."
sudo rm -f /usr/local/bin/aiws

echo "4/5 Removing Docker images and cache..."
if command -v docker >/dev/null 2>&1; then
    docker rmi aiws-cli aiws-harness aiws-app 2>/dev/null || true
    docker builder prune -f 2>/dev/null || true
fi

echo "5/5 Wiping runtime state and logs..."
rm -rf "$ROOT/runtime" "$ROOT/secrets" "$ROOT/.venv" "$ROOT/logs"

echo
echo "=========================================================="
echo "Uninstallation complete! AIWS has been removed from your system."
echo
echo "Note: Your cloned repositories in ~/projects were NOT deleted."
echo "To completely wipe the AIWS directory itself, run:"
echo "  cd ~ && rm -rf \"$ROOT\""
echo "=========================================================="
