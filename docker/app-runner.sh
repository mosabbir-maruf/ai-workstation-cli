#!/usr/bin/env bash
set -u

PID_FILE="/run/ai-workstation-cli/app/pid"
PGID_FILE="/run/ai-workstation-cli/app/pgid"
LOG_FILE="/run/ai-workstation-cli/app/app.log"

cleanup() {
    rm -f "$PID_FILE" "$PGID_FILE"
}

rm -f "$PID_FILE" "$PGID_FILE"
: > "$LOG_FILE"

cd /workspace || exit 1

setsid bash -lc 'exec "$@"' -- "$@" >>"$LOG_FILE" 2>&1 &
pid=$!

pgid="$(ps -o pgid= -p "$pid" | tr -d ' ')"

if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ ! "$pgid" =~ ^[0-9]+$ ]]; then
    kill "$pid" 2>/dev/null || true
    exit 1
fi

echo "$pid" > "$PID_FILE"
echo "$pgid" > "$PGID_FILE"

trap cleanup EXIT

wait "$pid"
status=$?

exit "$status"
