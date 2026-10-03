#!/usr/bin/env bash
set -euo pipefail

export NARB_DISABLE_NATIVE_CACHE=1

DSH_BIN="/home/sandbox/.npm-global/node_modules/@deepseek-ai/dsh/lib/bin.js"

DSH_HOST="127.0.0.1"
DSH_PORT="4090"
BRIDGE_HOST="0.0.0.0"
BRIDGE_PORT="4091"

RUNTIME_DIR="/run/ai-workstation-cli/harness"
DSH_PID_FILE="$RUNTIME_DIR/dsh.pid"
BRIDGE_PID_FILE="$RUNTIME_DIR/bridge.pid"
LOG_FILE="$RUNTIME_DIR/harness.log"

mkdir -p "$RUNTIME_DIR"

dsh_running() {
    [[ -f "$DSH_PID_FILE" ]] || return 1

    local pid
    pid="$(cat "$DSH_PID_FILE" 2>/dev/null || true)"

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    kill -0 "$pid" 2>/dev/null && (echo >/dev/tcp/127.0.0.1/4090) >/dev/null 2>&1
}

bridge_running() {
    [[ -f "$BRIDGE_PID_FILE" ]] || return 1

    local pid
    pid="$(cat "$BRIDGE_PID_FILE" 2>/dev/null || true)"

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    kill -0 "$pid" 2>/dev/null
}

cleanup_stale_state() {
    if ! dsh_running; then
        rm -f "$DSH_PID_FILE"
    fi

    if ! bridge_running; then
        rm -f "$BRIDGE_PID_FILE"
    fi
}

sync_dsh_config() {
    node -e '
        const fs = require("fs");
        const dshDir = "/home/sandbox/.dsh";
        const uiFile = dshDir + "/ui-providers.json";
        const credFile = dshDir + "/.credentials.yaml";
        const setFile = dshDir + "/settings.yaml";

        if (!fs.existsSync(uiFile)) process.exit(0);
        let ui = {};
        try { ui = JSON.parse(fs.readFileSync(uiFile, "utf8")); } catch { process.exit(0); }
        const provs = (ui && typeof ui.api_providers === "object" && ui.api_providers) || {};

        const refs = {};
        const piProviders = {};
        let defaultRoute = null;

        const map = [
            { uiKey: "deepseek", env: "DEEPSEEK_API_KEY", piKey: null, name: "DeepSeek", defModel: "deepseek-chat" },
            { uiKey: "gemini", env: "GEMINI_API_KEY", piKey: "google", name: "Google Gemini", defModel: "gemini-2.5-flash" },
            { uiKey: "openai", env: "OPENAI_API_KEY", piKey: "openai", name: "OpenAI", defModel: "gpt-4o" },
            { uiKey: "anthropic", env: "ANTHROPIC_API_KEY", piKey: "anthropic", name: "Anthropic Claude", defModel: "claude-3-7-sonnet-20250219" },
            { uiKey: "openrouter", env: "OPENROUTER_API_KEY", piKey: "openrouter", name: "OpenRouter", defModel: "deepseek/deepseek-r1" },
            { uiKey: "groq", env: "GROQ_API_KEY", piKey: "groq", name: "Groq", defModel: "llama-3.3-70b-versatile" },
            { uiKey: "custom", env: "CUSTOM_API_KEY", piKey: "custom", name: "Custom / Local", defModel: "deepseek-r1" },
        ];

        for (const m of map) {
            const entry = provs[m.uiKey] || (m.uiKey === "gemini" ? provs.google : null) || {};
            const key = String(entry.api_key || "").trim();
            const model = String(entry.model || "").trim() || m.defModel;
            const baseUrl = String(entry.base_url || "").trim();

            const rawHeaders = entry.headers && typeof entry.headers === "object" && !Array.isArray(entry.headers) ? entry.headers : null;
            let cleanHeaders = undefined;
            if (rawHeaders) {
                const cleanEntries = Object.entries(rawHeaders)
                    .filter(([k, v]) => typeof k === "string" && k.trim() && typeof v === "string" && v.trim())
                    .map(([k, v]) => [k.trim(), v.trim()]);
                if (cleanEntries.length > 0) {
                    cleanHeaders = Object.fromEntries(cleanEntries);
                }
            }
            const compat = entry.compat && typeof entry.compat === "object" && !Array.isArray(entry.compat) && Object.keys(entry.compat).length > 0
                ? entry.compat
                : undefined;

            if (key) {
                refs[m.env] = key;
                if (m.uiKey === "gemini") refs["GOOGLE_GENERATIVE_AI_API_KEY"] = key;
            }

            if (key || (m.uiKey === "custom" && baseUrl)) {
                const modelIds = model.split(",").map((s) => s.trim()).filter(Boolean);
                const modelList = (modelIds.length ? modelIds : [m.defModel]).map((id) => ({ id, name: id }));
                if (!defaultRoute) {
                    defaultRoute = m.uiKey === "deepseek"
                        ? { provider: "deepseek-official", model: modelList[0].id }
                        : { provider: m.piKey, model: modelList[0].id };
                }
                if (m.piKey) {
                    piProviders[m.piKey] = m.piKey === "custom"
                        ? {
                            displayName: m.name,
                            ...(key ? { apiKeyEnv: m.env } : {}),
                            api: "openai-completions",
                            baseURL: baseUrl || "http://127.0.0.1:11434/v1",
                            models: modelList,
                            ...(cleanHeaders ? { headers: cleanHeaders } : {}),
                            ...(compat ? { compat } : {}),
                        }
                        : {
                            displayName: m.name,
                            apiKeyEnv: m.env,
                            models: modelList,
                            ...(cleanHeaders ? { headers: cleanHeaders } : {}),
                            ...(compat ? { compat } : {}),
                        };
                }
            }
        }

        const patchFile = dshDir + "/cordis.patch.yml";
        const hasDeepseek = Boolean(refs["DEEPSEEK_API_KEY"]);
        const patchYaml = hasDeepseek
            ? "- id: llm-deepseek\n  disabled: false\n"
            : "- id: llm-deepseek\n  disabled: true\n- id: llm-deepseek-account\n  disabled: true\n";
        fs.writeFileSync(patchFile, patchYaml, { mode: 0o600 });

        fs.writeFileSync(credFile, JSON.stringify({ version: 1, refs }, null, 2) + "\n", { mode: 0o600 });
        try { fs.chmodSync(credFile, 0o600); } catch {}

        let settingsDoc = {};
        if (fs.existsSync(setFile)) {
            try {
                const raw = JSON.parse(fs.readFileSync(setFile, "utf8"));
                if (raw && typeof raw === "object" && !Array.isArray(raw)) settingsDoc = raw;
            } catch {}
        }
        delete settingsDoc.api_providers;
        settingsDoc["llm-pi-ai"] = { providers: piProviders };
        if (defaultRoute) {
            settingsDoc["agent-default-model"] = defaultRoute;
        }
        fs.writeFileSync(setFile, JSON.stringify(settingsDoc, null, 2) + "\n", { mode: 0o600 });
        try { fs.chmodSync(setFile, 0o600); } catch {}

        for (const [k, v] of Object.entries(refs)) {
            console.log("export " + k + "=" + JSON.stringify(v));
        }
    ' 2>/dev/null || true
}

start_dsh() {
    if dsh_running; then
        return 0
    fi

    echo "Starting DSH..."

    cd /workspace 2>/dev/null || {
        echo "ERROR: workspace mount missing" >&2
        return 1
    }

    local dsh_args=(web --host "$DSH_HOST" --port "$DSH_PORT" --no-open)
    local trusted="${DSH_TRUSTED_HOSTS:-}"
    local entry
    for entry in ${trusted//,/ }; do
        [[ -n "$entry" ]] && dsh_args+=(--trusted-host "$entry")
    done

    # Patch dsh-hmr only once if needed (instant check vs full node_modules scan)
    local hmr_file="/home/sandbox/.npm-global/node_modules/@deepseek-ai/dsh-hmr/lib/index.js"
    if [[ -f "$hmr_file" ]] && grep -q 'if (hmr === void 0) throw' "$hmr_file" 2>/dev/null; then
        sed -i 's/if (hmr === void 0) throw/if (hmr === void 0) return; \/\/ throw/g' "$hmr_file" 2>/dev/null || true
    fi

    local env_exports=""
    env_exports="$(sync_dsh_config)"
    if [[ -n "$env_exports" ]]; then
        eval "$env_exports"
    fi

    node --expose-internals "$DSH_BIN" \
        "${dsh_args[@]}" >>"$LOG_FILE" 2>&1 &

    echo "$!" > "$DSH_PID_FILE"
}

start_bridge() {
    if bridge_running; then
        return 0
    fi

    echo "Starting Harness bridge..."

    node -e '
        const net = require("net");
        const fs = require("fs");

        const server = net.createServer((socket) => {
            const target = net.connect(4090, "127.0.0.1", () => {
                socket.pipe(target);
                target.pipe(socket);
            });

            target.on("error", () => socket.destroy());
            socket.on("error", () => target.destroy());
        });

        server.listen(4091, "0.0.0.0");

        // Self-terminate bridge if DSH (4090) stops listening so host probes never see a zombie bridge
        setInterval(() => {
            const probe = net.connect(4090, "127.0.0.1", () => probe.destroy());
            probe.on("error", () => {
                try { fs.unlinkSync("/run/ai-workstation-cli/harness/dsh.pid"); } catch {}
                try { fs.unlinkSync("/run/ai-workstation-cli/harness/bridge.pid"); } catch {}
                process.exit(0);
            });
        }, 3000).unref();
    ' >>"$LOG_FILE" 2>&1 &

    echo "$!" > "$BRIDGE_PID_FILE"
}

stop_process() {
    local pid_file="$1"

    [[ -f "$pid_file" ]] || return 0

    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"

    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        kill -TERM "$pid" 2>/dev/null || true

        for _ in {1..20}; do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi

            sleep 0.1
        done

        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$pid_file"
}

cmd_start() {
    cleanup_stale_state
    : > "$LOG_FILE"

    start_dsh

    # Wait up to 6s for DSH to bind port 4090 before starting the bridge.
    local dsh_ready=0
    for _ in {1..60}; do
        if (echo >/dev/tcp/127.0.0.1/4090) >/dev/null 2>&1; then
            dsh_ready=1
            break
        fi
        sleep 0.1
    done

    if [[ "$dsh_ready" -ne 1 ]]; then
        echo "ERROR: DSH failed to bind port 4090." >&2
        cat "$LOG_FILE" >&2 || true
        rm -f "$DSH_PID_FILE"
        return 1
    fi

    start_bridge

    echo "Harness started."
}

cmd_stop() {
    stop_process "$BRIDGE_PID_FILE"
    stop_process "$DSH_PID_FILE"

    echo "Harness stopped."
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_status() {
    cleanup_stale_state

    local dsh_status="stopped"
    local bridge_status="stopped"

    if dsh_running; then
        dsh_status="running"
    fi

    if bridge_running; then
        bridge_status="running"
    fi

    echo "=== Harness ==="
    echo "DSH:    $dsh_status"
    echo "Bridge: $bridge_status"

    if [[ "$dsh_status" == "running" && "$bridge_status" == "running" ]]; then
        return 0
    fi

    return 1
}

case "${1:-}" in
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        cmd_restart
        ;;
    status)
        cmd_status
        ;;
    sync)
        sync_dsh_config >/dev/null
        ;;
    *)
        echo "Usage: harness {start|stop|restart|status|sync}"
        exit 1
        ;;
esac
