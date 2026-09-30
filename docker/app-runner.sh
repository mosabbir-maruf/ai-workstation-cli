#!/usr/bin/env bash
set -u

APP_DIR="/run/ai-workstation-cli/app"
PID_FILE="$APP_DIR/pid"
PGID_FILE="$APP_DIR/pgid"
LOG_FILE="$APP_DIR/app.log"

# Ensure app-runner itself is a session/process-group leader (PGID == $$)
# so setsid never forks a background orphan and exits early.
current_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
if [[ -n "$current_pgid" && "$current_pgid" != "$$" && "${_AIWS_SETSID:-0}" != "1" ]]; then
    export _AIWS_SETSID=1
    exec setsid "$0" "$@"
fi

mkdir -p "$APP_DIR" 2>/dev/null || true
rm -f "$PID_FILE" "$PGID_FILE"
export PATH="/home/sandbox/.npm-global/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}"

# Normalize arguments: if invoked with `bash -lc` or `sh -lc`, convert to `-c`
# so Debian /etc/profile does not overwrite PATH and strip npm-global/bin.
cmd_args=("$@")
if [[ "${cmd_args[0]:-}" == "bash" && "${cmd_args[1]:-}" == "-lc" ]]; then
    cmd_args[1]="-c"
elif [[ "${cmd_args[0]:-}" == "sh" && "${cmd_args[1]:-}" == "-lc" ]]; then
    cmd_args[1]="-c"
fi

bash -c 'export PATH="/home/sandbox/.npm-global/bin:$PATH"; exec "$@"' _ "${cmd_args[@]}" >>"$LOG_FILE" 2>&1 &
child_pid=$!
pgid="$$"

echo "$child_pid" > "$PID_FILE"
echo "$pgid" > "$PGID_FILE"

cleanup() {
    rm -f "$PID_FILE" "$PGID_FILE"
}
trap cleanup EXIT

wait "$child_pid"
exit $?
