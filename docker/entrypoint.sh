#!/usr/bin/env bash
set -euo pipefail

export HOME=/home/sandbox
export NPM_CONFIG_PREFIX=/home/sandbox/.npm-global
export PATH=/home/sandbox/.npm-global/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/sbin:/usr/bin:/bin
export NARB_DISABLE_NATIVE_CACHE=1

DSH_VERSION="${DSH_VERSION:-0.1.2-rc.1}"
DSH_BIN="/home/sandbox/.npm-global/node_modules/@deepseek-ai/dsh/lib/bin.js"
DSH_LINK="/home/sandbox/.npm-global/bin/dsh"

mkdir -p "$NPM_CONFIG_PREFIX/bin"

# Ensure environment files for login/interactive shells include npm-global in PATH
mkdir -p "$HOME" 2>/dev/null || true
for prof in "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.bashrc"; do
    if ! grep -q 'npm-global/bin' "$prof" 2>/dev/null; then
        echo 'export PATH="/home/sandbox/.npm-global/bin:$PATH"' >> "$prof" 2>/dev/null || true
    fi
done

# Pre-install pnpm if missing so it is immediately available
if ! command -v pnpm >/dev/null 2>&1; then
    echo "Pre-installing pnpm..."
    npm install --prefix "$NPM_CONFIG_PREFIX" -g pnpm 2>/dev/null || true
fi

if [[ ! -f "$DSH_BIN" ]]; then
    echo "Installing DeepSeek Harness ${DSH_VERSION}..."

    npm install --prefix "$NPM_CONFIG_PREFIX" \
        "@deepseek-ai/dsh@${DSH_VERSION}"
fi

# npm may install the package without creating the global executable.
# Always ensure the DSH CLI is available as `dsh`.
ln -sf "$DSH_BIN" "$DSH_LINK"
chmod +x "$DSH_BIN"

git config --global --unset-all credential.helper 2>/dev/null || true
git config --global credential.helper /usr/local/bin/github-app-credential-helper
git config --global credential.useHttpPath true

echo "DSH runtime: $(node "$DSH_BIN" --version)"

exec "$@"
