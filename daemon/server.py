#!/usr/bin/env python3
"""
AI Workstation Host Control Daemon
High-performance, zero-dependency async HTTP bridge daemon that connects
the AI Workstation Web Dashboard (bklit-ui) directly to the CLI and system state.

Runs natively with Python 3.8+ (asyncio + http.server / socketserver) on loopback.
Port: 8000 (default)
"""

import asyncio
import glob
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Paths
ROOT = Path(os.environ.get("AI_WORKSTATION_ROOT", str(Path(__file__).resolve().parent.parent)))
ENV_FILE = ROOT / ".env"
RUNTIME_DIR = ROOT / "runtime"
PROJECTS_DIR = Path.home() / "projects"
DSH_DIR = RUNTIME_DIR / "dsh"
DSH_SETTINGS_FILE = DSH_DIR / "settings.yaml"
APP_RUNTIME_DIR = RUNTIME_DIR / "app"
APP_PID_FILE = APP_RUNTIME_DIR / "pid"
HARNESS_RUNTIME_DIR = RUNTIME_DIR / "harness"
HARNESS_LOG_FILE = HARNESS_RUNTIME_DIR / "harness.log"
APP_LOG_FILE = APP_RUNTIME_DIR / "app.log"
GITHUB_BROKER_SOCKET = RUNTIME_DIR / "github-broker" / "github.sock"
GITHUB_PEM_FILE = ROOT / "secrets" / "github-app.pem"
BACKUPS_DIR = Path.home() / "ai-state-backups"

DAEMON_HOST = os.environ.get("WORKSTATION_DAEMON_HOST", "127.0.0.1")
DAEMON_PORT = int(os.environ.get("WORKSTATION_DAEMON_PORT", "8000"))

START_TIME = time.time()


def read_env() -> dict:
    values = {}
    if ENV_FILE.is_file():
        try:
            for line in ENV_FILE.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip()
        except Exception:
            pass
    return values


def run_cmd(cmd: list, timeout: float = 30.0) -> tuple:
    try:
        res = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            cwd=str(ROOT),
        )
        return res.returncode == 0, res.stdout.strip()
    except subprocess.TimeoutExpired:
        return False, f"Command timed out after {timeout}s: {' '.join(cmd)}"
    except Exception as e:
        return False, str(e)


def is_container_running(name: str = "ai-workstation-cli") -> bool:
    ok, out = run_cmd(["docker", "ps", "--format", "{{.Names}}"], timeout=5.0)
    if ok and out:
        return any(line.strip() == name for line in out.splitlines())
    return False


def get_container_ip() -> str:
    ok, out = run_cmd(
        ["docker", "inspect", "ai-workstation-cli", "--format", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}"],
        timeout=4.0,
    )
    if ok and out:
        ip = out.strip().splitlines()[0] if out.splitlines() else ""
        if re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
            return ip
    return ""


def get_detected_ports() -> list:
    ports_script = ROOT / "scripts" / "lib" / "ports.sh"
    if ports_script.is_file():
        ok, out = run_cmd(["bash", str(ports_script)], timeout=5.0)
        if ok and out:
            return [p.strip() for p in out.split() if p.strip()]
    return []


def is_app_running() -> bool:
    if not APP_PID_FILE.is_file():
        return False
    try:
        pid = APP_PID_FILE.read_text().strip()
        if not pid.isdigit():
            return False
        ok, _ = run_cmd(["docker", "exec", "ai-workstation-cli", "sh", "-c", f"kill -0 {pid} 2>/dev/null"], timeout=3.0)
        return ok
    except Exception:
        return False


def format_bytes(b: int) -> str:
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if b < 1024.0:
            return f"{b:.1f} {unit}"
        b /= 1024.0
    return f"{b:.1f} PB"


def collect_metrics() -> dict:
    # Memory
    mem_total = 0
    mem_used = 0
    mem_free = 0
    try:
        with open("/proc/meminfo", "r") as f:
            lines = f.readlines()
        mem_dict = {}
        for line in lines:
            parts = line.split(":")
            if len(parts) == 2:
                key = parts[0].strip()
                val = parts[1].strip().split()[0]
                if val.isdigit():
                    mem_dict[key] = int(val) * 1024  # convert kB to Bytes
        mem_total = mem_dict.get("MemTotal", 0)
        mem_available = mem_dict.get("MemAvailable", mem_dict.get("MemFree", 0))
        mem_free = mem_available
        mem_used = max(0, mem_total - mem_free)
    except Exception:
        # Fallback for Darwin/other
        mem_total = 8 * 1024 * 1024 * 1024
        mem_used = 3 * 1024 * 1024 * 1024
        mem_free = mem_total - mem_used

    mem_percent = round((mem_used / mem_total * 100), 1) if mem_total else 0.0

    # CPU & Load Average
    cores = os.cpu_count() or 1
    try:
        load_tuple = os.getloadavg()
    except Exception:
        load_tuple = (0.0, 0.0, 0.0)
    cpu_percent = min(100.0, round((load_tuple[0] / cores) * 100, 1))

    # Docker & system containers/daemons
    total_daemons = 5
    active_daemons = 0
    if is_container_running():
        active_daemons += 2  # Container + DSH
    if is_app_running():
        active_daemons += 1
    if GITHUB_BROKER_SOCKET.is_socket():
        active_daemons += 1
    # Cloudflared active check
    ok, _ = run_cmd(["systemctl", "is-active", "--quiet", "cloudflared"], timeout=2.0)
    if ok:
        active_daemons += 1

    # Uptime
    uptime_sec = int(time.time() - START_TIME)
    try:
        with open("/proc/uptime", "r") as f:
            uptime_sec = int(float(f.readline().split()[0]))
    except Exception:
        pass
    days, rem = divmod(uptime_sec, 86400)
    hours, rem = divmod(rem, 3600)
    mins, _ = divmod(rem, 60)
    uptime_str = f"{days}d {hours}h {mins}m" if days else f"{hours}h {mins}m"

    now_iso = datetime.now(timezone.utc).isoformat()

    return {
        "memory": {
            "totalBytes": mem_total,
            "usedBytes": mem_used,
            "freeBytes": mem_free,
            "usedPercent": mem_percent,
            "totalFormatted": format_bytes(mem_total),
            "usedFormatted": format_bytes(mem_used),
            "pie": [
                {"label": "Used", "value": mem_used},
                {"label": "Free", "value": mem_free},
            ],
        },
        "cpu": {
            "cores": cores,
            "model": platform.processor() or "AMD/Intel x86_64",
            "loadAvg": [round(load_tuple[0], 2), round(load_tuple[1], 2), round(load_tuple[2], 2)],
            "usagePercent": cpu_percent,
        },
        "daemons": {
            "totalCount": total_daemons,
            "activeCount": active_daemons,
            "rings": [
                {"label": "Services", "value": active_daemons, "maxValue": total_daemons},
            ],
        },
        "throughput": [
            {"month": "Cur", "ingress": 120, "egress": 85, "buffered": 10},
        ],
        "timeline": [
            {"date": now_iso, "cpu": cpu_percent, "memory": mem_percent},
        ],
        "uptime": uptime_str,
        "hostname": socket.gethostname(),
        "platform": f"{platform.system()} {platform.release()}",
    }


def get_active_project_git_info(project_name: str) -> dict:
    if not project_name:
        return None
    proj_path = PROJECTS_DIR / project_name
    if not (proj_path / ".git").is_dir():
        return None

    def git_read(args: list) -> str:
        ok, out = run_cmd(["git", "-C", str(proj_path)] + args, timeout=3.0)
        return out.strip() if ok else ""

    branch = git_read(["branch", "--show-current"]) or "main"
    last_msg = git_read(["log", "-1", "--format=%s"]) or "Initial commit"
    last_time = git_read(["log", "-1", "--format=%cd", "--date=iso-strict"]) or ""
    dirty_count = 0
    ok, status_out = run_cmd(["git", "-C", str(proj_path), "status", "--porcelain"], timeout=3.0)
    if ok and status_out:
        dirty_count = len(status_out.splitlines())

    return {
        "name": project_name,
        "branch": branch,
        "lastCommitMessage": last_msg,
        "lastCommitTime": last_time,
        "dirtyFilesCount": dirty_count,
    }


# Request Router
async def handle_request(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        request_line = await asyncio.wait_for(reader.readline(), timeout=15.0)
        if not request_line:
            writer.close()
            return

        line_str = request_line.decode("utf-8", errors="replace").strip()
        parts = line_str.split()
        if len(parts) < 2:
            writer.close()
            return

        method = parts[0].upper()
        path = parts[1]

        # Read headers
        headers = {}
        content_length = 0
        while True:
            header_line = await asyncio.wait_for(reader.readline(), timeout=15.0)
            if not header_line or header_line == b"\r\n" or header_line == b"\n":
                break
            h_str = header_line.decode("utf-8", errors="replace").strip()
            if ":" in h_str:
                hk, hv = h_str.split(":", 1)
                headers[hk.strip().lower()] = hv.strip()
                if hk.strip().lower() == "content-length":
                    try:
                        content_length = int(hv.strip())
                    except ValueError:
                        pass

        body = b""
        if content_length > 0:
            body = await asyncio.wait_for(reader.readexactly(content_length), timeout=30.0)

        # Handle CORS OPTIONS
        if method == "OPTIONS":
            writer.write(
                b"HTTP/1.1 204 No Content\r\n"
                b"Access-Control-Allow-Origin: *\r\n"
                b"Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n"
                b"Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
                b"Content-Length: 0\r\n\r\n"
            )
            await writer.drain()
            writer.close()
            return

        parsed_json = {}
        if body:
            try:
                parsed_json = json.loads(body.decode("utf-8", errors="replace"))
            except Exception:
                pass

        # Parse Clean Path
        clean_path = path.split("?")[0].rstrip("/")

        # SSE Streaming endpoints
        if clean_path in ["/api/logs/app", "/api/logs/workstation", "/api/tunnel/logs"]:
            await stream_logs(clean_path, writer)
            return

        # Route matching
        status_code = 200
        resp_data = {"ok": True}

        # 1. Health
        if clean_path == "/api/health":
            resp_data = {"ok": True, "output": "Host workstation daemon active."}

        # 2. Status & Overview
        elif clean_path == "/api/status":
            env = read_env()
            container_ok = is_container_running()
            app_ok = is_app_running()
            active_proj = env.get("ACTIVE_PROJECT", "")

            # Output string matching CLI `ai status`
            summary = [
                "=== AI Workstation ===",
                f"Active project: {active_proj or 'none'}",
                f"Project path: {env.get('ACTIVE_PROJECT_PATH', 'none')}",
                "",
                f"Workstation: {'running' if container_ok else 'stopped'}",
                f"App: {'running' if app_ok else 'stopped'}",
            ]
            resp_data = {
                "ok": True,
                "output": "\n".join(summary),
                "metrics": collect_metrics(),
            }

        # 3. Workstation Container Lifecycle
        elif clean_path == "/api/workstation/start":
            ok, out = run_cmd(["ai", "start"], timeout=60.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/workstation/stop":
            ok, out = run_cmd(["ai", "stop"], timeout=30.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/workstation/restart":
            ok, out = run_cmd(["ai", "restart"], timeout=60.0)
            resp_data = {"ok": ok, "output": out}

        # 4. App Lifecycle inside container
        elif clean_path == "/api/app/run":
            ok, out = run_cmd(["ai", "run"], timeout=90.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/app/stop":
            ok, out = run_cmd(["ai", "app", "stop"], timeout=15.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/app/restart":
            ok, out = run_cmd(["ai", "app", "restart"], timeout=90.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/app/status":
            ok, out = run_cmd(["ai", "app", "status"], timeout=5.0)
            resp_data = {"ok": ok, "output": out}

        # 5. Projects
        elif clean_path == "/api/projects":
            env = read_env()
            active_proj = env.get("ACTIVE_PROJECT", "")
            projects_list = []
            if PROJECTS_DIR.is_dir():
                for p in sorted(PROJECTS_DIR.iterdir()):
                    if p.is_dir() and (p / ".git").is_dir():
                        projects_list.append({
                            "name": p.name,
                            "active": p.name == active_proj,
                        })
            raw_lines = ["Projects:"]
            for pr in projects_list:
                mark = "*" if pr["active"] else " "
                raw_lines.append(f"  {mark} {pr['name']}")
            if not projects_list:
                raw_lines.append("  (none)")

            resp_data = {
                "ok": True,
                "projects": projects_list,
                "raw": "\n".join(raw_lines),
                "output": "\n".join(raw_lines),
                "activeProject": get_active_project_git_info(active_proj),
            }
        elif clean_path == "/api/projects/use":
            name = parsed_json.get("name", "").strip()
            if not name:
                status_code = 400
                resp_data = {"ok": False, "output": "Missing project name"}
            else:
                ok, out = run_cmd(["ai", "use", name], timeout=45.0)
                resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/projects/add":
            url = parsed_json.get("url", "").strip()
            if not url:
                status_code = 400
                resp_data = {"ok": False, "output": "Missing repository url"}
            else:
                ok, out = run_cmd(["ai", "add", url], timeout=120.0)
                resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/projects/remove":
            name = parsed_json.get("name", "").strip()
            if not name:
                status_code = 400
                resp_data = {"ok": False, "output": "Missing project name"}
            else:
                ok, out = run_cmd(["ai", "remove", name], timeout=30.0)
                resp_data = {"ok": ok, "output": out}

        # 6. Git Operations
        elif clean_path == "/api/git/pull":
            ok, out = run_cmd(["ai", "pull"], timeout=60.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/git/push":
            msg = parsed_json.get("message", "Update from AI Workstation").strip()
            ok, out = run_cmd(["ai", "push", msg], timeout=60.0)
            resp_data = {"ok": ok, "output": out}

        # 7. Harness & DSH
        elif clean_path == "/api/harness/start":
            ok, out = run_cmd(["ai", "harness", "start"], timeout=30.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/harness/stop":
            ok, out = run_cmd(["ai", "harness", "stop"], timeout=15.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/harness/restart":
            ok, out = run_cmd(["ai", "harness", "restart"], timeout=30.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/harness/status":
            ok, out = run_cmd(["ai", "harness", "status"], timeout=5.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/dsh/version":
            ok, out = run_cmd(["ai", "dsh", "version"], timeout=5.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/dsh/update":
            ver = parsed_json.get("version", "").strip()
            cmd = ["ai", "dsh", "update"]
            if ver:
                cmd.append(ver)
            ok, out = run_cmd(cmd, timeout=180.0)
            resp_data = {"ok": ok, "output": out}

        # 8. DSH Settings (YAML)
        elif clean_path == "/api/dsh-settings":
            if method == "GET":
                content = ""
                mtime = ""
                if DSH_SETTINGS_FILE.is_file():
                    try:
                        content = DSH_SETTINGS_FILE.read_text(encoding="utf-8")
                        mtime = datetime.fromtimestamp(
                            DSH_SETTINGS_FILE.stat().st_mtime, tz=timezone.utc
                        ).isoformat()
                    except Exception as e:
                        content = f"# Error reading settings: {e}"
                resp_data = {"ok": True, "content": content, "mtime": mtime}
            elif method == "POST":
                new_content = parsed_json.get("content", "")
                try:
                    DSH_DIR.mkdir(parents=True, exist_ok=True)
                    DSH_SETTINGS_FILE.write_text(new_content, encoding="utf-8")
                    DSH_SETTINGS_FILE.chmod(0o600)
                    resp_data = {"ok": True, "output": "DSH settings saved successfully"}
                except Exception as e:
                    status_code = 500
                    resp_data = {"ok": False, "output": f"Failed to save settings: {e}"}

        # 9. Preview & Anywhere URLs
        elif clean_path == "/api/preview":
            ok, out = run_cmd(["ai", "preview"], timeout=8.0)
            env = read_env()
            app_host = env.get("CLOUDFLARED_APP_HOSTNAME", "")
            dsh_host = env.get("CLOUDFLARED_DSH_HOSTNAME", "")

            dsh_token_url = ""
            if HARNESS_LOG_FILE.is_file():
                try:
                    log_text = HARNESS_LOG_FILE.read_text(errors="replace")
                    match = re.search(r"http://127\.0\.0\.1:4090([^\s'\"]*)", log_text)
                    if match and match.group(1) and match.group(1) != "/":
                        dsh_token_url = f"https://{dsh_host}{match.group(1)}" if dsh_host else ""
                except Exception:
                    pass

            resp_data = {
                "ok": ok,
                "text": out,
                "anywhereApp": f"https://{app_host}" if app_host else "",
                "anywhereDsh": dsh_token_url or (f"https://{dsh_host}" if dsh_host else ""),
            }

        # 10. Tunnel Operations
        elif clean_path == "/api/tunnel/status":
            ok, out = run_cmd(["ai", "tunnel", "status"], timeout=5.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/tunnel/start":
            ok, out = run_cmd(["ai", "tunnel", "start"], timeout=15.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/tunnel/stop":
            ok, out = run_cmd(["ai", "tunnel", "stop"], timeout=15.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/tunnel/sync":
            port = parsed_json.get("port")
            cmd = ["ai", "tunnel", "sync"]
            if port is not None:
                cmd.append(str(port))
            ok, out = run_cmd(cmd, timeout=15.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/tunnel/setup":
            token = parsed_json.get("token", "").strip()
            app_host = parsed_json.get("appHost", "").strip()
            dsh_host = parsed_json.get("dshHost", "").strip()
            app_port = parsed_json.get("appPort", 3000)

            if not token or not app_host or not dsh_host:
                status_code = 400
                resp_data = {"ok": False, "output": "token, appHost, and dshHost are required"}
            else:
                # Automate non-interactive setup
                secrets_dir = ROOT / "secrets"
                secrets_dir.mkdir(parents=True, exist_ok=True)
                secrets_dir.chmod(0o700)
                token_file = secrets_dir / "cloudflared-token"
                token_file.write_text(token)
                token_file.chmod(0o600)

                # Ensure cloudflared service installed
                srv_installed, _ = run_cmd(["sudo", "cloudflared", "service", "install", token], timeout=30.0)
                run_cmd(["sudo", "systemctl", "restart", "cloudflared"], timeout=10.0)

                # Update .env
                env_vals = read_env()
                env_vals["CLOUDFLARED_TOKEN_SET"] = "1"
                env_vals["CLOUDFLARED_APP_HOSTNAME"] = app_host
                env_vals["CLOUDFLARED_DSH_HOSTNAME"] = dsh_host
                env_vals["CLOUDFLARED_APP_PORT"] = str(app_port)
                env_vals["DSH_TRUSTED_HOSTS"] = dsh_host
                env_vals["ALLOWED_HOSTS"] = app_host

                lines = [f"{k}={v}" for k, v in env_vals.items()]
                ENV_FILE.write_text("\n".join(lines) + "\n")
                ENV_FILE.chmod(0o600)

                resp_data = {"ok": True, "output": "Cloudflare Tunnel connector configured successfully"}

        # 11. GitHub Integration
        elif clean_path == "/api/github/status":
            ok, out = run_cmd(["ai", "github", "status"], timeout=5.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/github/test":
            ok, out = run_cmd(["ai", "github", "test"], timeout=15.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/github/setup":
            app_id = parsed_json.get("appId", "").strip()
            inst_id = parsed_json.get("installationId", "").strip()
            pem_text = parsed_json.get("pemText", "").strip()

            if not app_id or not inst_id or not pem_text:
                status_code = 400
                resp_data = {"ok": False, "output": "appId, installationId, and pemText are required"}
            else:
                secrets_dir = ROOT / "secrets"
                secrets_dir.mkdir(parents=True, exist_ok=True)
                secrets_dir.chmod(0o700)
                GITHUB_PEM_FILE.write_text(pem_text)
                GITHUB_PEM_FILE.chmod(0o600)

                env_vals = read_env()
                env_vals["GITHUB_APP_ID"] = app_id
                env_vals["GITHUB_INSTALLATION_ID"] = inst_id
                lines = [f"{k}={v}" for k, v in env_vals.items()]
                ENV_FILE.write_text("\n".join(lines) + "\n")
                ENV_FILE.chmod(0o600)

                # Restart broker service
                run_cmd(["sudo", "systemctl", "restart", "ai-github-broker"], timeout=10.0)
                ok, out = run_cmd(["ai", "github", "test"], timeout=10.0)
                resp_data = {"ok": ok, "output": out}

        # 12. Maintenance (Cache & Doctor)
        elif clean_path == "/api/cache":
            ok, out = run_cmd(["ai", "cache"], timeout=15.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/cache/clear":
            deps = parsed_json.get("deps", False)
            cmd = ["ai", "cache", "clear", "--yes"]
            if deps:
                cmd.append("--deps")
            ok, out = run_cmd(cmd, timeout=60.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/system/doctor":
            ok, out = run_cmd(["ai", "doctor"], timeout=20.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/system/update":
            ok, out = run_cmd(["ai", "update"], timeout=120.0)
            resp_data = {"ok": ok, "output": out}
        elif clean_path == "/api/system/upgrade":
            ok, out = run_cmd(["ai", "upgrade"], timeout=180.0)
            resp_data = {"ok": ok, "output": out}

        # 13. State Management
        elif clean_path == "/api/state/export":
            ok, out = run_cmd(["ai", "state", "export"], timeout=60.0)
            filename = ""
            if ok:
                match = re.search(r"(ai-state-\d+-\d+\.tar\.gz)", out)
                if match:
                    filename = match.group(1)
            resp_data = {
                "ok": ok,
                "output": out,
                "filename": filename,
                "downloadUrl": f"/api/state/download?file={filename}" if filename else "",
            }
        elif clean_path == "/api/state/download":
            # Send file directly
            query_file = ""
            if "?" in path:
                query_file = dict(x.split("=", 1) for x in path.split("?")[1].split("&") if "=" in x).get("file", "")
            if not query_file:
                # Latest
                backups = sorted(BACKUPS_DIR.glob("ai-state-*.tar.gz"), reverse=True)
                target = backups[0] if backups else None
            else:
                target = (BACKUPS_DIR / Path(query_file).name).resolve()

            if target and target.is_file():
                file_bytes = target.read_bytes()
                writer.write(
                    f"HTTP/1.1 200 OK\r\n"
                    f"Content-Type: application/gzip\r\n"
                    f"Content-Disposition: attachment; filename=\"{target.name}\"\r\n"
                    f"Content-Length: {len(file_bytes)}\r\n"
                    f"Access-Control-Allow-Origin: *\r\n\r\n".encode("utf-8")
                )
                writer.write(file_bytes)
                await writer.drain()
                writer.close()
                return
            else:
                status_code = 404
                resp_data = {"ok": False, "output": "Archive not found"}

        elif clean_path == "/api/state/import":
            # Saves upload and runs import
            BACKUPS_DIR.mkdir(parents=True, exist_ok=True)
            temp_archive = BACKUPS_DIR / f"import-{int(time.time())}.tar.gz"
            temp_archive.write_bytes(body)
            ok, out = run_cmd(["ai", "state", "import", str(temp_archive)], timeout=60.0)
            resp_data = {"ok": ok, "output": out}

        else:
            status_code = 404
            resp_data = {"ok": False, "output": f"Endpoint not found: {clean_path}"}

        # Send JSON Response
        body_bytes = json.dumps(resp_data).encode("utf-8")
        resp_headers = (
            f"HTTP/1.1 {status_code} OK\r\n"
            f"Content-Type: application/json; charset=utf-8\r\n"
            f"Content-Length: {len(body_bytes)}\r\n"
            f"Access-Control-Allow-Origin: *\r\n"
            f"Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n"
            f"Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
            f"Connection: close\r\n\r\n"
        ).encode("utf-8")

        writer.write(resp_headers)
        writer.write(body_bytes)
        await writer.drain()

    except Exception as e:
        err_msg = json.dumps({"ok": False, "output": str(e)}).encode("utf-8")
        writer.write(
            b"HTTP/1.1 500 Internal Error\r\n"
            b"Content-Type: application/json\r\n"
            b"Access-Control-Allow-Origin: *\r\n\r\n" + err_msg
        )
        await writer.drain()
    finally:
        writer.close()


async def stream_logs(endpoint: str, writer: asyncio.StreamWriter):
    """Streams live logs via Server-Sent Events (SSE) with minimal buffer overhead."""
    writer.write(
        b"HTTP/1.1 200 OK\r\n"
        b"Content-Type: text/event-stream; charset=utf-8\r\n"
        b"Cache-Control: no-cache, no-transform\r\n"
        b"Connection: keep-alive\r\n"
        b"Access-Control-Allow-Origin: *\r\n\r\n"
    )
    await writer.drain()

    target_cmd = []
    if endpoint == "/api/logs/app":
        target_cmd = ["docker", "exec", "ai-workstation-cli", "sh", "-c", "tail -n 80 -f /run/ai-workstation-cli/app/app.log 2>/dev/null || sleep 1"]
    elif endpoint == "/api/logs/workstation":
        target_cmd = ["docker", "logs", "--tail", "80", "-f", "ai-workstation-cli"]
    elif endpoint == "/api/tunnel/logs":
        target_cmd = ["sudo", "journalctl", "-u", "cloudflared", "-n", "80", "-f"]

    try:
        proc = await asyncio.create_subprocess_exec(
            *target_cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )

        while True:
            line = await proc.stdout.readline()
            if not line:
                break
            clean_line = line.decode("utf-8", errors="replace").rstrip("\r\n")
            sse_packet = f"event: message\ndata: {clean_line}\n\n".encode("utf-8")
            writer.write(sse_packet)
            await writer.drain()

    except Exception:
        pass
    finally:
        try:
            writer.write(b"event: end\ndata: [STREAM_COMPLETED]\n\n")
            await writer.drain()
        except Exception:
            pass
        writer.close()


async def main():
    server = await asyncio.start_server(handle_request, DAEMON_HOST, DAEMON_PORT)
    addr = server.sockets[0].getsockname()
    print(f"AI Workstation Host Control Daemon listening on http://{addr[0]}:{addr[1]}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nDaemon stopped.")
        sys.exit(0)
