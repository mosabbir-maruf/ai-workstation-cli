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

git -C "$ROOT" pull --ff-only

if command -v ai >/dev/null 2>&1; then
    ai upgrade
else
    "$ROOT/install.sh"
fi
