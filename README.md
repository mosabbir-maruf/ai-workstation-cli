<p align="center">
  <img src="docs/assets/logo.svg" alt="AIWS Logo" width="120" height="120" />
</p>

<h1 align="center">AIWS</h1>

---

<p align="center">
  <strong>A secure and reusable development workstation for VPS, with isolated Docker projects, DeepSeek Harness, GitHub App authentication, SSH previews, and simple lifecycle management.</strong>
  <br />
  <em>Looking for the web console? Check out the <a href="https://github.com/mosabbir-maruf/aiws">AIWS Web Interface</a>.</em>
</p>

<p align="center">
  <a href="https://github.com/mosabbir-maruf/ai-workstation-cli/actions/workflows/image.yml"><img src="https://github.com/mosabbir-maruf/ai-workstation-cli/actions/workflows/image.yml/badge.svg" alt="Build AIWS" /></a>
  <a href="https://github.com/mosabbir-maruf/ai-workstation-cli/pkgs/container/aiws-cli"><img src="https://img.shields.io/badge/GHCR-ai--workstation--cli-blue?logo=docker" alt="Docker Image" /></a>
  <a href="https://github.com/mosabbir-maruf/ai-workstation-cli"><img src="https://img.shields.io/badge/platform-linux%2Famd64%2Carm64-informational" alt="Platform" /></a>
  <a href="https://www.docker.com/"><img src="https://img.shields.io/badge/runtime-Docker-blue" alt="Runtime" /></a>
  <a href="https://github.com/deepseek-ai/deepseek-harness"><img src="https://img.shields.io/badge/AI%20runtime-DeepSeek%20Harness-black" alt="AI Runtime" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT" /></a>
  <a href="CONTRIBUTING.md"><img src="https://img.shields.io/badge/contributions-welcome-brightgreen.svg" alt="Contributing" /></a>
  <a href="SECURITY.md"><img src="https://img.shields.io/badge/security-policy-red.svg" alt="Security Policy" /></a>
  <a href="https://github.com/mosabbir-maruf"><img src="https://img.shields.io/badge/maintainer-Mosabbir%20Maruf-181717?logo=github" alt="Maintainer" /></a>
</p>

<p align="center">
  <img src="docs/assets/tui.png" alt="AIWS Interactive Terminal UI" width="850" />
</p>

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Security Model](#security-model)
- [Repository Structure](#repository-structure)
- [Host Runtime Structure](#host-runtime-structure)
- [Requirements](#requirements)
- [Clone the Repository](#clone-the-repository)
- [Installation](#installation)
- [Configuration](#configuration)
- [GitHub Authentication](#github-authentication)
- [Daily Workflow](#daily-workflow)
- [CLI Reference](#cli-reference)
- [Project Lifecycle](#project-lifecycle)
- [Harness and DSH Lifecycle](#harness-and-dsh-lifecycle)
- [Preview and SSH Tunneling](#preview-and-ssh-tunneling)
- [Anywhere Access via Cloudflare Tunnel](#anywhere-access-via-cloudflare-tunnel)
- [Git Workflow](#git-workflow)
- [Cache Management](#cache-management)
- [State Backup and Recovery](#state-backup-and-recovery)
- [Updates and Upgrades](#updates-and-upgrades)
- [CI/CD](#cicd)
- [Operational Runbook](#operational-runbook)
- [Troubleshooting](#troubleshooting)
- [Security Checklist](#security-checklist)
- [Design Decisions](#design-decisions)
- [Quick Reference](#quick-reference)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)
- [Maintainer](#maintainer)

---

## Overview

AIWS provides one reusable development environment on a remote Linux VPS.

Projects remain ordinary Git repositories on the host under `~/projects/`. Only the currently selected project is mounted into the workstation container at `/workspace`.

The workstation contains the common developer runtime and DeepSeek Harness. DSH installation and DSH state are persisted outside the disposable container filesystem, allowing the container/image to be replaced without intentionally losing Harness state.

The system has four major boundaries:

1. **Host management layer** — Docker, projects, runtime state, secrets, and the `aiws` CLI.
2. **Workstation container** — isolated developer runtime plus the selected project.
3. **GitHub broker** — GitHub App credential flow through a Unix socket instead of a PAT or host SSH key inside the container.
4. **Existing infrastructure** — the existing gateway/reverse-proxy stack remains separate.

---

## Architecture

### High-level architecture

```text
                                  INTERNET
                                      │
                       ┌──────────────┴──────────────┐
                       │                             │
                  SSH :1182                      HTTPS :443
                       │                             │
                       ▼                             ▼
                ┌────────────┐             ┌─────────────────────┐
                │ Mac / Admin│             │ Existing Reverse    │
                │   Client   │             │ Proxy / Nginx       │
                └─────┬──────┘             └──────────┬──────────┘
                      │                               │
                SSH tunnel                            ▼
                      │                      Existing application stack
                      ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                            Ubuntu VPS / Host                               │
│                                                                            │
│  ┌──────────────────────┐       ┌───────────────────────────────────────┐  │
│  │ ~/projects/          │       │ ~/aiws-cli/                 │  │
│  │                      │       │                                       │  │
│  │ project-a/           │       │ scripts/aiws                            │  │
│  │ project-b/           │       │ docker/                               │  │
│  │ active-project/ ─────┼──────►│ runtime/                              │  │
│  │                      │       │ secrets/                              │  │
│  └──────────┬───────────┘       │ .env                                  │  │
│             │                   └────────────────┬──────────────────────┘  │
│             │                                    │                         │
│             │ /workspace mount                   │ Docker Compose          │
│             ▼                                    ▼                         │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                          aiws-cli                          │  │
│  │                                                                      │  │
│  │  User: sandbox (UID 1001)                                            │  │
│  │  Node.js + Git + SSH client + ripgrep + fd + procps + tini           │  │
│  │                                                                      │  │
│  │  /workspace                  ← active project only                   │  │
│  │  /home/sandbox/.dsh          ← persistent DSH state                  │  │
│  │  /home/sandbox/.npm-global   ← persistent DSH installation           │  │
│  │                                                                      │  │
│  │  DSH:     127.0.0.1:4090                                             │  │
│  │  Bridge:  0.0.0.0:4091                                               │  │
│  │  App:     project-selected development port(s)                       │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                              ▲                                             │
│                              │ Unix socket                                 │
│                   ┌──────────┴───────────┐                                 │
│                   │ GitHub broker runtime│                                 │
│                   │ github.sock          │                                 │
│                   └──────────┬───────────┘                                 │
│                              │                                             │
│                   GitHub App private key                                   │
│                              │                                             │
│                   secrets/github-app.pem                                   │
└────────────────────────────────────────────────────────────────────────────┘
```

### Data flow

```text
Mac / operator
     │
     │ SSH
     ▼
Host CLI: aiws
     │
     ├── project selection
     ├── Git operations
     ├── workstation lifecycle
     ├── Harness lifecycle
     ├── app lifecycle
     ├── cache maintenance
     └── preview/tunnel generation
     │
     ▼
Docker workstation
     │
     ├── selected project at /workspace
     ├── persistent DSH state
     ├── persistent DSH installation
     ├── app runtime state
     ├── Harness runtime state
     └── GitHub broker socket
```

### Component responsibilities

| Component | Responsibility | Persistence |
|---|---|---|
| `scripts/aiws` | Main operator CLI | Git |
| `docker/Dockerfile` | Base workstation image | Git / GHCR |
| `docker/compose.yml` | Runtime, mounts, limits, ports | Git |
| `docker/entrypoint.sh` | Container bootstrap and DSH installation | Git |
| `docker/app-runner.sh` | Project process runner | Git |
| `docker/harness.sh` | DSH + bridge lifecycle | Git |
| `docker/github-app-credential-helper` | Container-side Git credential helper | Git |
| `scripts/lib/github.sh` | GitHub App/broker management | Git |
| `broker/` | Host-side broker implementation | Git |
| `runtime/dsh/` | DSH state/config/history | Host persistent |
| `runtime/npm-global/` | DSH installation | Host persistent |
| `runtime/app/` | App PID/log state | Disposable |
| `runtime/harness/` | Harness PID/log state | Disposable |
| `runtime/github-broker/` | Broker socket/runtime | Runtime |
| `~/projects/` | Git working copies | Host persistent |
| GitHub Actions | ARM64 image build/publish | CI |
| GHCR | Container image registry | External |

---

## Security Model

The workstation is intentionally isolated from sensitive host capabilities.

### Container security

The current runtime is configured to:

- run as non-root `sandbox` (UID `1001`);
- drop all Linux capabilities (`cap_drop: [ALL]`);
- enable `no-new-privileges: true`;
- remain non-privileged (`privileged: false`);
- limit memory to 512 MB;
- limit CPU to 1.5 CPUs;
- limit processes to 256 PIDs;
- use `/tmp` as `noexec,nosuid,size=128m` tmpfs;
- avoid host networking;
- avoid the host Docker socket (`/var/run/docker.sock` is never mounted);
- avoid mounting the host `~/.ssh`;
- mount only the active project at `/workspace`;
- mount the GitHub broker socket directory as read-only (`:ro`).

### Credential boundary

GitHub credentials do not need to be copied into the workstation.

```text
Git inside container
       │
       ▼
credential helper
       │
       ▼
Unix socket (/run/ai-github-broker/github.sock)
       │
       ▼
host GitHub broker (ai-github-broker service)
       │
       ▼
GitHub App authentication (RS256 JWT using secrets/github-app.pem)
       │
       ▼
GitHub API (short-lived in-memory token)
```

The credential helper does not persist GitHub tokens through Git's credential store.

### Secret locations

Sensitive files are host-only:

```text
.env                         mode 0600
secrets/github-app.pem       mode 0600
secrets/cloudflared-token    mode 0600
runtime/dsh/                 mode 0700
runtime/dsh/ui-providers.json mode 0600
runtime/dsh/.credentials.yaml mode 0600
```

Never commit private keys, tokens, credentials, or `.env`.

> [!WARNING]
> **Active Project Trust Boundary Notice:**  
> Code running inside `/workspace` executes as the container user `sandbox`. Because in-container Git requires access to the broker socket to clone and push code, any script running in the container can request temporary GitHub installation tokens for repositories granted to the GitHub App. Additionally, DSH runtime state (`~/.dsh`) is accessible to the container user. Only clone and execute repositories whose dependency trees you trust. For detailed threat modeling, see [SECURITY.md](SECURITY.md).

---

## Repository Structure

```text
ai-workstation-cli/
├── .env.example                     # Environment template
├── .dockerignore                    # Build context exclusions
├── .gitignore                       # Ignored runtime and local secrets
├── CONTRIBUTING.md                  # Contributor guidelines
├── LICENSE                          # MIT License
├── README.md                        # Primary architecture & operational guide
├── SECURITY.md                      # Security policy & threat boundary specs
├── install.sh                       # Host installation & systemd setup script
├── update.sh                        # Fast-forward update script
├── uninstall.sh                     # Idempotent host uninstallation script
│
├── .github/
│   ├── ISSUE_TEMPLATE/              # Bug and feature issue forms
│   └── workflows/
│       └── image.yml                # Automated test & multi-arch image workflow
│
├── broker/
│   └── github_broker.py             # Host-side GitHub App token broker
│
├── config/
│   └── projects.yml                 # Local project configuration registry
│
├── contracts/
│   └── openapi.yaml                 # Canonical OpenAPI 3.1 contract specification
│
├── daemon/
│   └── server.py                    # Host HTTP/SSE control bridge daemon (port 8000)
│
├── docker/
│   ├── Dockerfile                   # Node 22 Bookworm Slim multi-arch image
│   ├── compose.yml                  # Workstation runtime & security definition
│   ├── entrypoint.sh                # Container bootstrap & DSH link setup
│   ├── app-runner.sh                # Application supervisor process runner
│   ├── harness.sh                   # DSH agent engine + TCP bridge supervisor
│   └── github-app-credential-helper # Container-side credential helper
│
├── docs/
│   ├── github-app-setup.md          # Step-by-step GitHub App configuration guide
│   └── cloudflare-tunnel.md         # Remote ingress & Cloudflare Tunnel guide
│
├── scripts/
│   ├── aiws                         # Main CLI and interactive Terminal UI (TUI)
│   ├── github-app-credential-helper # Host-side Git credential helper
│   └── lib/
│       ├── github.sh                # GitHub App & broker service helpers
│       ├── tunnel.sh                # Cloudflare Tunnel helpers
│       └── ports.sh                 # Container listening port detector
│
└── tests/                           # Automated Python unit & integration test suite
    ├── test_auth.py                 # Fail-closed authentication & permissions tests
    ├── test_env_safety.py           # Non-executable literal .env parsing tests
    ├── test_sse_and_process.py      # Output bounding & concurrent SSE tests
    ├── test_ssrf_and_limits.py      # IP pinning, SSRF & HTTP framing tests
    └── test_state_transfer.py       # Raw gzip import & byte-identical download tests
```

---

## Host Runtime Structure

The host management layer maintains persistent state outside the disposable container:

| Path | Purpose | Persistence | Permissions |
|---|---|---|---|
| `~/projects/` | Git working copies of your projects | Host persistent | User default |
| `runtime/dsh/` | DSH agent conversation history and provider keys | Host persistent | `0700` (`0600` files) |
| `runtime/npm-global/` | Pinned `@deepseek-ai/dsh` package install | Host persistent | `0700` |
| `runtime/github-broker/` | Unix domain socket (`github.sock`) | Runtime socket | `0770` (group `ai-broker`) |
| `runtime/app/` | Dev server PID and output log state | Disposable | `0700` |
| `runtime/harness/` | DSH agent and TCP bridge PID/log state | Disposable | `0700` |
| `secrets/` | Host-only credentials (`github-app.pem`) | Host-only | `0700` (`0600` files) |
| `~/aiws-state-backups/`| Exported state snapshots (`.tar.gz`) | Host persistent | `0600` |

---

## Requirements

### Supported Platforms & Status

| Platform | Support Tier | Verification Status | Notes |
|---|---|---|---|
| **Ubuntu 24.04 / 22.04 LTS** | Tier 1 (Target Host) | Runtime verification pending | Recommended distribution for systemd background services and apt tooling. |
| **Debian 12 (Bookworm)** | Tier 1 (Compatible) | Runtime verification pending | Supported base for systemd units and packages. |
| **macOS (Darwin arm64 / x86_64)** | Development / Testing | Behaviorally verified | Full support for CLI commands, Docker builds, and automated unit tests. Host systemd units require Linux. |

### Software Prerequisites

- **Docker Engine:** `24.0+`
- **Docker Compose Plugin:** `v2.20+` (`docker compose version`)
- **Python:** `3.8+` with `venv` and `ensurepip` (`python3 --version`)
- **Git:** `2.30+` (`git --version`)
- **Bash:** `3.2+` (Bash 4+ recommended on Linux)
- **OpenSSL:** For generating cryptographic secrets (`openssl version`)
- **curl:** For health checks and API validation

---

## Clone the Repository

Clone into your user directory (default: `~/aiws-cli`):

```bash
git clone https://github.com/mosabbir-maruf/ai-workstation-cli.git ~/aiws-cli
cd ~/aiws-cli
```

---

## Installation

### Step-by-Step Setup

1. **Initialize configuration template:**
   ```bash
   cp .env.example .env
   chmod 600 .env
   ```

2. **Generate a cryptographically secure 32-byte daemon key:**
   ```bash
   KEY=$(openssl rand -hex 32)
   sed -i.bak "s|^WORKSTATION_API_KEY=.*|WORKSTATION_API_KEY=${KEY}|" .env && rm -f .env.bak
   ```

3. **Run the host installation script:**
   ```bash
   ./install.sh
   ```
   *What this performs:* sets up `.venv`, installs `PyJWT[crypto]`, initializes `runtime/` and `secrets/` with mode `0700`, installs `/usr/local/bin/aiws`, and registers `aiws-daemon` and `ai-github-broker` systemd units.

4. **Launch the primary workstation container:**
   ```bash
   aiws start
   ```

5. **Verify health status:**
   ```bash
   # CLI diagnostic probe
   aiws status
   aiws doctor

   # Daemon loopback health endpoint
   API_KEY=$(grep '^WORKSTATION_API_KEY=' .env | cut -d= -f2)
   curl -s -H "Authorization: Bearer $API_KEY" http://127.0.0.1:8000/api/health
   ```
   *Expected response:* `{"ok": true, "output": "Host workstation daemon active."}`

---

## Configuration

All configuration is managed through `.env`. The file must maintain mode `0600`.

### Configuration Reference Table

| Variable Key | Required? | Default / Example | Purpose & Scope | Security Precautions |
|---|---|---|---|---|
| `WORKSTATION_API_KEY` | **Yes** | `$(openssl rand -hex 32)` | Master Bearer credential for daemon (`server.py`). Required by frontend proxy. | Mode `0600`. Daemon refuses startup if missing or empty. |
| `AIWS_INSECURE_LOCAL` | Optional | `0` (or unset) | Set to `1` only to allow running daemon without an API key during offline development. | **Never enable in production.** Exposes arbitrary command execution. |
| `IMAGE` | Optional | `ghcr.io/mosabbir-maruf/aiws-cli:latest` | Workstation container image tag. | Pin to commit SHA (`@sha256:...`) in high-assurance setups. |
| `DSH_VERSION` | Optional | `0.1.2-rc.1` | Pinned npm package version for DeepSeek Harness (`@deepseek-ai/dsh`). | Updates can be applied via `aiws dsh update <version>`. |
| `ACTIVE_PROJECT` | Managed | `my-app` | Active project repository under `~/projects/`. | Managed automatically by `aiws use <project>`. |
| `ACTIVE_PROJECT_PATH` | Managed | `/home/<user>/projects/my-app` | Host path mounted to `/workspace` inside the container. | Auto-updated on project switch. |
| `WORKSTATION_DAEMON_HOST`| Optional | `127.0.0.1` | Network bind address for host control daemon. | Keep bound strictly to loopback (`127.0.0.1`). |
| `WORKSTATION_DAEMON_PORT`| Optional | `8000` | TCP port for daemon HTTP/SSE listener. | Ensure no host port conflict. |
| `GITHUB_APP_ID` | Optional | `123456` | GitHub App ID for brokered Git authentication. | Configured via `aiws github setup`. |
| `GITHUB_INSTALLATION_ID` | Optional | `7891011` | GitHub App Installation ID. | Configured via `aiws github setup`. |
| `ALLOWED_HOSTS` | Optional | `""` | Hostname allowlist for Vite/Next dev servers. | Populated by `aiws tunnel setup`. |
| `CLOUDFLARED_APP_HOSTNAME`| Optional | `app.example.com` | Public tunnel hostname for the active development server. | Set during Cloudflare tunnel setup. |
| `CLOUDFLARED_DSH_HOSTNAME`| Optional | `dsh.example.com` | Public tunnel hostname for DeepSeek Harness bridge. | Set during Cloudflare tunnel setup. |

To safely update configuration via CLI helper:

```bash
aiws config
```

---

## GitHub Authentication

GitHub authentication is brokered over a local Unix domain socket rather than copying PATs or SSH keys into the container:

```bash
# 1. Configure GitHub App credentials
aiws github setup <app_id> <installation_id> /path/to/private-key.pem

# 2. Test token generation
aiws github test
```

For complete step-by-step GitHub App creation, consult [docs/github-app-setup.md](docs/github-app-setup.md).

---

## Daily Workflow

```bash
# 1. Add and select a project
aiws add https://github.com/org/my-project.git
aiws use my-project

# 2. Launch application dev server
aiws run

# 3. Stream logs and inspect status
aiws status
aiws app logs

# 4. Synchronize Git changes safely
aiws diff
aiws pull
aiws push "feat: add user authentication"

# 5. Open an interactive shell inside the container
aiws shell
```

---

## CLI Reference

Launch the interactive Terminal UI (TUI) simply by running:

```bash
aiws
```

Direct command reference:

```text
PROJECTS
  aiws add <github-url>       Clone project into ~/projects/
  aiws use <project>          Select project and mount to /workspace
  aiws list                   List all local projects
  aiws remove <project>       Delete project checkout from host

CONTAINER & APP
  aiws start                  Start workstation container
  aiws stop                   Stop workstation container
  aiws restart                Restart container
  aiws status                 Display unified system and service status
  aiws shell                  Open bash prompt as sandbox user in /workspace
  aiws run                    Launch application development server
  aiws app status             Inspect application process state
  aiws app logs               Stream application dev server logs
  aiws app restart            Restart application process
  aiws app stop               Terminate application process

GIT OPERATIONS
  aiws diff                   Show working tree and staged diffs
  aiws pull                   Fast-forward pull from upstream origin
  aiws push "<commit message>" Verify no secrets staged, commit, and push

AGENT HARNESS (DSH)
  aiws harness status         Inspect DSH (4090) and Bridge (4091) processes
  aiws harness restart        Restart DSH and bridge supervisor
  aiws dsh version            Show installed @deepseek-ai/dsh package version
  aiws dsh update [version]   Update or reinstall DSH agent package

INGRESS & PREVIEWS
  aiws preview                Detect listening ports and print SSH forward command
  aiws tunnel setup           Configure Cloudflare Zero Trust tunnel connector
  aiws tunnel status          Inspect Cloudflare Tunnel connection status
  aiws tunnel sync [port]     Update tunnel ingress application port

MAINTENANCE & BACKUPS
  aiws doctor                 Run full diagnostic health check
  aiws cache prune            Prune Docker build caches and dangling images
  aiws state export           Create atomic .tar.gz snapshot in ~/aiws-state-backups/
  aiws state import <archive> Safely import state snapshot with rollback protection
  aiws upgrade                Pull latest verified codebase and restart services
  aiws uninstall              Remove background services, containers, and CLI links
```

---

## Project Lifecycle

When you run `aiws use <project>`, AIWS updates `ACTIVE_PROJECT` and `ACTIVE_PROJECT_PATH` in `.env`, automatically re-creates the container with the newly selected project mounted at `/workspace`, and configures container-side Git credentials. Unselected repositories in `~/projects/` remain completely unmounted.

---

## Harness and DSH Lifecycle

DeepSeek Harness runs inside the workstation container:
- The DSH process listens on `127.0.0.1:4090`.
- A Node.js TCP bridge exposes DSH to container `0.0.0.0:4091`, mapped to host `127.0.0.1:4090`.
- Agent settings and conversation histories persist on the host under `runtime/dsh/`.
- Provider API keys (DeepSeek, OpenAI, Anthropic, Gemini, Groq, OpenRouter, and custom local models) are managed atomically in `runtime/dsh/ui-providers.json` with mode `0600`.

---

## Preview and SSH Tunneling

AIWS binds all development ports strictly to `127.0.0.1` on the host. To view applications running on your remote VPS:

```bash
aiws preview
```

Copy the generated SSH port-forwarding command to your local machine:

```bash
ssh -N -L 3000:127.0.0.1:3000 -L 5173:127.0.0.1:5173 user@your-vps-ip
```

Open `http://localhost:3000` or `http://localhost:5173` in your local browser.

---

## Anywhere Access via Cloudflare Tunnel

To securely access development previews and DSH without open firewall ports, configure a Cloudflare Zero Trust tunnel:

```bash
aiws tunnel setup
```

Consult [docs/cloudflare-tunnel.md](docs/cloudflare-tunnel.md) for full configuration steps and hostname mapping instructions.

---

## Git Workflow

The `aiws push` command protects operators from accidental credential disclosure:
1. Verifies that Git author credentials (`user.name`, `user.email`) are configured.
2. Stages changes and inspects staged filenames against sensitive patterns (`.env`, `*.pem`, `*.key`, `credentials.json`, `service-account*.json`).
3. Rejects commits immediately if sensitive patterns match.
4. Commits with your provided commit message and pushes to origin via the GitHub App credential broker.

---

## Cache Management

To reclaim disk space on your VPS:

```bash
aiws cache prune
```

This cleans Docker build caches, dangling layers, and temporary runtime logs without touching your project repositories or DSH agent state.

---

## State Backup and Recovery

### Exporting State

```bash
aiws state export
```

Exports a `.tar.gz` archive to `~/aiws-state-backups/` containing your `.env` configuration and `runtime/dsh/` agent history.

### Importing State

```bash
aiws state import ~/aiws-state-backups/aiws-state-20261014-120000.tar.gz
```

**Rollback Guarantee:** AIWS validates archive paths and symlinks before extraction. It creates temporary backups of your existing `.env` and `runtime/dsh`. If extraction or replacement fails, your previous state is automatically restored.

---

## Updates and Upgrades

To update AIWS to the latest release:

```bash
./update.sh
```

The updater pulls the latest verified git commit, verifies dependencies, and restarts daemon services cleanly.

---

## CI/CD

The repository includes an automated GitHub Actions workflow (`.github/workflows/image.yml`) that:
1. Runs Python compilation (`py_compile`) across all daemons and brokers.
2. Validates Bash script syntax (`bash -n`) across all CLI and Docker scripts.
3. Validates Docker Compose configuration (`docker compose config --quiet`).
4. Executes the automated Python unit test suite (`unittest`).
5. Builds and publishes multi-architecture container images (`linux/amd64`, `linux/arm64`) to the GitHub Container Registry (`ghcr.io/mosabbir-maruf/aiws-cli`).

---

## Operational Runbook

### Routine Service Management

```bash
# Check daemon and broker status
systemctl status aiws-daemon ai-github-broker

# Restart daemon after configuration updates
sudo systemctl restart aiws-daemon

# Stream live daemon logs
journalctl -u aiws-daemon -f
```

### Pre-Flight Operations Checklist

- [ ] `.env` permissions are `0600` (`stat -c '%a %n' .env` returns `600`).
- [ ] `WORKSTATION_API_KEY` is populated with a strong 32-byte hexadecimal key.
- [ ] `docker compose -f docker/compose.yml config --quiet` passes without errors.
- [ ] Automated tests pass (`python3 -m unittest discover tests`).
- [ ] Local health check responds with HTTP 200:
  ```bash
  API_KEY=$(grep '^WORKSTATION_API_KEY=' .env | cut -d= -f2)
  curl -fsS -H "Authorization: Bearer $API_KEY" http://127.0.0.1:8000/api/health
  ```

---

## Troubleshooting

| Observed Symptom | Likely Cause | Diagnostic Check | Corrective Action | When to Stop & Escalate |
|---|---|---|---|---|
| Daemon exits with `ERROR: WORKSTATION_API_KEY is not configured` (exit 1). | `WORKSTATION_API_KEY` missing or empty in `.env`. | `grep "^WORKSTATION_API_KEY=" .env` | Run `KEY=$(openssl rand -hex 32) && echo "WORKSTATION_API_KEY=$KEY" >> .env`. | If file exists but daemon fails to read, check permissions (`chmod 600 .env`). |
| API calls to `127.0.0.1:8000` return `401 Unauthorized`. | Missing, mismatched, or malformed `Authorization: Bearer` header. | Inspect client request headers; compare against `.env`. | Pass `Authorization: Bearer <key>`. Query string tokens (`?token=`) are rejected. | Do not disable authentication in production. |
| Port conflict on `8000`, `3000`, `5173`, or `4090`. | Competing process or stale container bound to the port. | `sudo lsof -nP -iTCP:<port> -sTCP:LISTEN` | Stop competing process or run `docker compose -f docker/compose.yml down`. | Never kill unknown host processes with `kill -9` without confirming PID ownership. |
| Git commands fail with `fatal: could not read Username`. | GitHub broker socket missing or service stopped. | `ls -la runtime/github-broker/github.sock` and `aiws github status` | Start service: `sudo systemctl restart ai-github-broker` or run `aiws github test`. | If private key is missing (`secrets/github-app.pem`), re-upload PEM and run `aiws github setup`. |
| `aiws state import` fails with `State archive contains unsafe or unexpected files`. | Archive contains path traversal (`../`), absolute paths, or unapproved files. | `tar -tzf <archive>` | Ensure archive was created via `aiws state export`. Rollback preserves prior state automatically. | Verify archive structure matches `manifest`, `.env`, and `dsh/*`. |
| Container fails to start (`Error response from daemon`). | Corrupted mount path, Docker daemon stopped, or RAM exhausted. | `systemctl status docker` and `docker compose -f docker/compose.yml config` | Ensure Docker is active. Run `docker compose -f docker/compose.yml down -v` and retry `aiws start`. | If Docker daemon crashes repeatedly, inspect disk space (`df -h`) and `journalctl -u docker`. |
| Development server runs but browser shows `Invalid Host Header`. | Framework dev server rejects incoming tunnel hostname. | `echo $ALLOWED_HOSTS` | Add tunnel hostname to `ALLOWED_HOSTS` in `.env`: `ALLOWED_HOSTS=app.example.com`. | Do not set `ALLOWED_HOSTS=*` on sensitive production origins. |
| SSE log stream terminates unexpectedly. | Process was reaped or client connection disconnected. | `aiws app status` | Ensure target application is running before streaming logs (`aiws run`). | If daemon crashes during streaming, check daemon log file. |

---

## Security Checklist

Before exposing any service or sharing access:

- [ ] `WORKSTATION_API_KEY` is generated and kept secret in `.env`.
- [ ] `.env` and `secrets/github-app.pem` have mode `0600`.
- [ ] Daemon is bound strictly to `127.0.0.1:8000`.
- [ ] Container runs with `cap_drop: [ALL]` and `no-new-privileges: true`.
- [ ] Docker socket `/var/run/docker.sock` is **never** mounted.
- [ ] Host `~/.ssh` is **never** mounted into containers.
- [ ] Unrestricted sudo (`NOPASSWD: ALL`) is absent from `/etc/sudoers.d/aiws`.

---

## Design Decisions

- **One Workstation, Many Projects:** Common developer tools live in the container image; project working trees stay on the host under `~/projects/` and mount individually.
- **Active-Project-Only Mount:** Only the selected repository is mounted to `/workspace`, preventing untrusted scripts from accessing other project repositories.
- **Brokered GitHub Credentials:** GitHub App authentication is brokered via Unix socket, avoiding personal access tokens (PATs) or host SSH keys inside the container.
- **Persistent DSH State Outside Container:** DSH conversation memory and settings live in `runtime/dsh/` on the host, surviving container rebuilds and image updates.
- **Loopback-Bound Services:** Ports are bound strictly to `127.0.0.1`, requiring explicit SSH port forwarding or authenticated Cloudflare Tunnels for access.

---

## Quick Reference

```text
PROJECTS
  aiws add <github-url>
  aiws remove <project>
  aiws list
  aiws use <project>

CONTAINER & APP
  aiws start
  aiws stop
  aiws restart
  aiws status
  aiws shell
  aiws run
  aiws app stop
  aiws app restart
  aiws app status
  aiws app logs

GIT
  aiws diff
  aiws pull
  aiws push "commit message"

AGENT HARNESS
  aiws harness start
  aiws harness stop
  aiws harness restart
  aiws harness status
  aiws dsh version
  aiws dsh update [version]

PREVIEW & TUNNEL
  aiws preview
  aiws tunnel setup
  aiws tunnel sync [port]
  aiws tunnel status
  aiws tunnel logs

MAINTENANCE
  aiws doctor
  aiws cache prune
  aiws state export
  aiws state import <archive>
  aiws upgrade
  aiws uninstall
```

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on development workflow, branch naming, coding standards, shell scripting guidelines, and validation requirements before opening a pull request.

---

## Security

Security is foundational to AIWS. To report a security vulnerability or learn more about our container isolation boundaries, credential helper architecture, and defense-in-depth model, please consult [SECURITY.md](SECURITY.md).

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for the full license text.

---

## Maintainer

Developed and maintained by [**Mosabbir Maruf**](https://github.com/mosabbir-maruf).

[![GitHub Profile](https://img.shields.io/badge/GitHub-mosabbir--maruf-181717?style=flat&logo=github)](https://github.com/mosabbir-maruf)

---

## Maintainer Notes

This repository is the source of truth for the workstation infrastructure and operator tooling.

Keep the following out of Git:
- Host runtime state (`runtime/`).
- Project working copies (`~/projects/`).
- `.env`.
- Private keys (`secrets/`).
- DSH credentials (`runtime/dsh/.credentials.yaml`).
- Temporary files and build caches.

Use GitHub for project source code and the state export mechanism (`aiws state export`) for DSH and workstation state recovery.

---

## Uninstallation

To remove AIWS, including background services, Docker containers, global CLI symlinks, caches, and runtime state:

```bash
aiws uninstall
```

*(You can also access the uninstaller directly from the `aiws` interactive dashboard, or run `./uninstall.sh`).*

The uninstaller **will not** delete any of your cloned project repositories inside `~/projects`. If you wish to delete them manually, run `rm -rf ~/projects`.
