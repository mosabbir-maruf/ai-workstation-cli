#!/usr/bin/env bash
set -u

APP_DIR="/run/aiws-cli/app"
PID_FILE="$APP_DIR/pid"
PGID_FILE="$APP_DIR/pgid"
BRIDGE_PID_FILE="$APP_DIR/bridge.pid"
LOG_FILE="$APP_DIR/app.log"

# Ensure app-runner itself is a session/process-group leader (PGID == $$)
# so setsid never forks a background orphan and exits early.
current_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
if [[ -n "$current_pgid" && "$current_pgid" != "$$" && "${_AIWS_SETSID:-0}" != "1" ]]; then
    export _AIWS_SETSID=1
    exec setsid "$0" "$@"
fi

mkdir -p "$APP_DIR" 2>/dev/null || true
rm -f "$PID_FILE" "$PGID_FILE" "$BRIDGE_PID_FILE"
export PATH="/home/sandbox/.npm-global/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}"
export HOST="${HOST:-0.0.0.0}"
export HOSTNAME="${HOSTNAME:-0.0.0.0}"
cd /workspace || exit 1

# Normalize arguments: if single string, wrap in bash -c; if bash -lc / sh -lc, strip -l
if [[ "$#" -eq 1 ]]; then
    cmd_args=(bash -c "$1")
else
    cmd_args=("$@")
    if [[ "${cmd_args[0]:-}" == "bash" || "${cmd_args[0]:-}" == "sh" ]]; then
        if [[ "${cmd_args[1]:-}" == "-lc" || "${cmd_args[1]:-}" == "-cl" ]]; then
            cmd_args[1]="-c"
        fi
    fi
fi

"${cmd_args[@]}" >>"$LOG_FILE" 2>&1 &
child_pid=$!
pgid="$$"

echo "$child_pid" > "$PID_FILE"
echo "$pgid" > "$PGID_FILE"

# Dual-port bridge: ensure both 3000 and 5173 reach the active application
node -e '
const net = require("net");
const p1 = 3000, p2 = 5173;
let activeBridge = null;

function probeAndBridge() {
  if (activeBridge) return;
  function tryBridge(primary, secondary) {
    const probe = net.createConnection({ port: primary, host: "127.0.0.1" });
    probe.on("connect", () => {
      probe.destroy();
      const checkSecondary = net.createConnection({ port: secondary, host: "127.0.0.1" });
      checkSecondary.on("connect", () => {
        checkSecondary.destroy();
      });
      checkSecondary.on("error", () => {
        try {
          const server = net.createServer((from) => {
            const to = net.createConnection({ port: primary, host: "127.0.0.1" });
            from.pipe(to);
            to.pipe(from);
            from.on("error", () => to.destroy());
            to.on("error", () => from.destroy());
          });
          server.on("error", () => {
            activeBridge = null;
          });
          server.listen(secondary, "0.0.0.0", () => {
            activeBridge = server;
            clearInterval(timer);
          });
        } catch {}
      });
    });
    probe.on("error", () => {});
  }
  tryBridge(p1, p2);
  tryBridge(p2, p1);
}

const timer = setInterval(probeAndBridge, 1000);
' >/dev/null 2>&1 &
bridge_pid=$!
echo "$bridge_pid" > "$BRIDGE_PID_FILE" 2>/dev/null || true

cleanup() {
    rm -f "$PID_FILE" "$PGID_FILE" "$BRIDGE_PID_FILE"
    kill "$bridge_pid" 2>/dev/null || true
}
trap cleanup EXIT

wait "$child_pid"
exit $?
