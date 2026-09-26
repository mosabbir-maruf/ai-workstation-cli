<p align="center">
  <img src="docs/assets/logo.svg" alt="AI Workstation Logo" width="120" height="120" />
</p>

<h1 align="center">AI Workstation</h1>

<p align="center">
  A reusable, isolated AI coding workstation for running DeepSeek Harness (DSH) and project development workloads on a remote Linux VPS.
  <br />
  <em>Looking for the web console? Check out the <a href="https://github.com/mosabbir-maruf/ai-workstation">AI Workstation Web Interface</a>.</em>
</p>

<p align="center">
  <a href="https://github.com/mosabbir-maruf/ai-workstation-cli"><img src="https://img.shields.io/badge/platform-linux%2Famd64%2Carm64-informational" alt="Platform" /></a>
  <a href="https://www.docker.com/"><img src="https://img.shields.io/badge/runtime-Docker-blue" alt="Runtime" /></a>
  <a href="https://github.com/deepseek-ai/deepseek-harness"><img src="https://img.shields.io/badge/AI%20runtime-DeepSeek%20Harness-black" alt="AI Runtime" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT" /></a>
  <a href="CONTRIBUTING.md"><img src="https://img.shields.io/badge/contributions-welcome-brightgreen.svg" alt="Contributing" /></a>
  <a href="SECURITY.md"><img src="https://img.shields.io/badge/security-policy-red.svg" alt="Security Policy" /></a>
  <a href="https://github.com/mosabbir-maruf"><img src="https://img.shields.io/badge/maintainer-Mosabbir%20Maruf-181717?logo=github" alt="Maintainer" /></a>
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

AI Workstation provides one reusable development environment on a remote Linux VPS.

Projects remain ordinary Git repositories on the host under `~/projects/`. Only the currently selected project is mounted into the workstation container at `/workspace`.

The workstation contains the common developer runtime and DeepSeek Harness. DSH installation and DSH state are persisted outside the disposable container filesystem, allowing the container/image to be replaced without intentionally losing Harness state.

The system has four major boundaries:

1. **Host management layer** — Docker, projects, runtime state, secrets, and the `ai` CLI.
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
│  │ ~/projects/          │       │ ~/ai-workstation-cli/                 │  │
│  │                      │       │                                       │  │
│  │ project-a/           │       │ scripts/ai                            │  │
│  │ project-b/           │       │ docker/                               │  │
│  │ active-project/ ─────┼──────►│ runtime/                              │  │
│  │                      │       │ secrets/                              │  │
│  └──────────┬───────────┘       │ .env                                  │  │
│             │                   └────────────────┬──────────────────────┘  │
│             │                                    │                         │
│             │ /workspace mount                   │ Docker Compose          │
│             ▼                                    ▼                         │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                          ai-workstation-cli                          │  │
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
Host CLI: ai
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
| `scripts/ai` | Main operator CLI | Git |
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
- drop all Linux capabilities;
- enable `no-new-privileges`;
- remain non-privileged;
- limit memory to 512 MB;
- limit CPU to 1.5 CPUs;
- limit processes to 256 PIDs;
- use `/tmp` as `noexec,nosuid`;
- avoid host networking;
- avoid the host Docker socket;
- avoid mounting the host `~/.ssh`;
- mount only the active project at `/workspace`.

### Credential boundary

GitHub credentials do not need to be copied into the workstation.

```text
Git inside container
       │
       ▼
credential helper
       │
       ▼
Unix socket
       │
       ▼
host GitHub broker
       │
       ▼
GitHub App authentication
       │
       ▼
GitHub
```

The credential helper does not persist GitHub tokens through Git's credential store.

### Secret locations

Sensitive files are host-only:

```text
.env
secrets/github-app.pem
runtime/dsh/.credentials.yaml
```

Recommended permissions:

```text
.env                         600
secrets/github-app.pem       600
runtime/dsh/                 700
runtime/dsh/.credentials...  600
```

Never commit private keys, tokens, credentials, or `.env`.

---

## Repository Structure

```text
ai-workstation-cli/
├── .env.example                     # Environment template
├── .gitignore                       # Ignored secrets, runtime, and OS files
├── CONTRIBUTING.md                  # Contributor guidelines
├── LICENSE                          # MIT License
├── README.md                        # Primary architecture & user documentation
├── SECURITY.md                      # Security policy and disclosure process
├── install.sh                       # Host installation and validation script
├── update.sh                        # Fast-forward update and upgrade script
│
├── .github/
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.yml           # Structured bug report form
│   │   ├── feature_request.yml      # Structured feature request form
│   │   └── config.yml               # Issue template configuration
│   ├── workflows/
│   │   └── image.yml                # Multi-arch GHCR build & publish workflow
│   └── pull_request_template.md     # PR submission template
│
├── broker/
│   └── github_broker.py             # Host-side GitHub App credential broker
│
├── config/
│   └── projects.yml                 # Project configuration registry
│
├── docs/
│   ├── github-app-setup.md          # GitHub App key walkthrough
│   └── cloudflare-tunnel.md         # Anywhere-access guide
│
├── docker/
│   ├── Dockerfile                   # Base multi-arch workstation image
│   ├── compose.yml                 # Runtime/security configuration
│   ├── entrypoint.sh               # Container bootstrap & DSH setup
│   ├── app-runner.sh               # App process runner
│   ├── harness.sh                  # DSH + bridge lifecycle
│   └── github-app-credential-helper# Container-side credential helper
│
└── scripts/
    ├── ai                           # Main CLI
    ├── github-app-credential-helper # Host-side credential helper
    └── lib/
        ├── github.sh                # GitHub App/broker helpers
        ├── tunnel.sh                # Cloudflare Tunnel helpers
        └── ports.sh                 # Shared container port detector
```

> [!NOTE]
> `runtime/`, `.env`, `.venv/`, `secrets/`, and project checkouts under `~/projects/` are local host runtime paths and are intentionally excluded from version control.

---

## Host Runtime Structure

```text
~/
├── ai-workstation-cli/
│   ├── .env
│   ├── .venv/
│   ├── runtime/
│   │   ├── dsh/
│   │   ├── npm-global/
│   │   ├── app/
│   │   ├── harness/
│   │   └── github-broker/
│   └── secrets/
│       ├── github-app.pem
│       └── cloudflared-token  # Tunnel connector token (optional)
│
└── projects/
    ├── project-a/.git
    ├── project-b/.git
    └── active-project/.git
```

Only the selected project is mounted into `/workspace`.

---

## Requirements

### Host

- Linux host with Docker.
- Docker Compose support.
- Git.
- Python 3.
- `sudo`.
- GitHub access to the repositories you will manage.
- Linux host (amd64 or arm64) for the published multi-arch image, or a local Docker build otherwise.

The included installer validates Docker, Git, Python 3, Docker daemon access, and Python virtual-environment support.

### Recommended server posture

- SSH key authentication.
- Password authentication disabled.
- Root SSH login disabled.
- Firewall default deny for incoming traffic.
- Only required public ports open.
- Development ports bound to localhost.

---

## Clone the Repository

```bash
git clone https://github.com/mosabbir-maruf/ai-workstation-cli.git ~/ai-workstation-cli
cd ~/ai-workstation-cli
```

---

## Installation

```bash
./install.sh
```

The installer:

1. validates host prerequisites;
2. installs Python `venv` support if needed;
3. creates runtime/project/secret directories;
4. creates `.env` from `.env.example`;
5. creates the Python virtual environment;
6. installs the required Python dependency;
7. installs `ai` at `/usr/local/bin/ai`;
8. validates the resulting installation.

Then:

```bash
ai doctor
ai github setup
ai github status
ai github test
```

---

## Configuration

`.env.example` currently contains:

```dotenv
IMAGE=ghcr.io/mosabbir-maruf/ai-workstation-cli:latest
DSH_VERSION=0.1.2-rc.1
ACTIVE_PROJECT=
ACTIVE_PROJECT_PATH=
AI_WORKSTATION_ROOT=
DSH_TRUSTED_HOSTS=
ALLOWED_HOSTS=
GITHUB_APP_ID=
GITHUB_INSTALLATION_ID=
GITHUB_BROKER_SOCKET=
GITHUB_BROKER_GID=
CLOUDFLARED_TOKEN_SET=
CLOUDFLARED_APP_HOSTNAME=
CLOUDFLARED_DSH_HOSTNAME=
CLOUDFLARED_APP_PORT=
```

The CLI also maintains GitHub App/broker and tunnel-related values locally when configured.

### Rules

- Keep `.env` private.
- Never commit `.env`.
- Keep `secrets/github-app.pem` private.
- Keep `secrets/cloudflared-token` private.
- Prefer trusted/pinned image references for controlled deployments.
- Pin `DSH_VERSION` when deterministic behavior is required.

---

## GitHub Authentication

GitHub access is brokered through a GitHub App. No PAT or SSH private key is copied into the workstation container.

Full walkthrough (App creation, private-key generation, copying the key to the VPS, macOS `scp` fix): [docs/github-app-setup.md](docs/github-app-setup.md).

Quick reference (on the VPS):

```bash
ai github setup
ai github status
ai github test
```

The private key belongs at `~/ai-workstation-cli/secrets/github-app.pem` (mode `600`). A healthy test reports:

```text
GitHub authentication: READY ✓
```

---

## Daily Workflow

### Start

```bash
ai start
```

### Check

```bash
ai status
```

### Start active project

```bash
ai run
```

### Preview

```bash
ai preview
```

### Stop project

```bash
ai app stop
```

### Stop workstation

```bash
ai stop
```

### Typical session

```bash
ai doctor
ai start
ai run
ai preview

# Work with DSH / editor / browser

ai app logs
ai status

ai app stop
ai stop
```

---

## CLI Reference

The command-line interface is maintained in [mosabbir-maruf/ai-workstation-cli](https://github.com/mosabbir-maruf/ai-workstation-cli).

Run:

```bash
ai
```

for the built-in command list.

### Projects

```bash
ai add <github-url>
ai remove <project>
ai list
ai use <project>
```

`ai add` clones a GitHub HTTPS repository into `~/projects/<name>`.

`ai use` selects which project is mounted at `/workspace`.

### Git

```bash
ai pull
ai push "commit message"
```

`ai pull` uses fast-forward-only Git behavior.

`ai push` checks staged filenames for common sensitive-file patterns before committing/pushing.

### Workstation

```bash
ai start
ai stop
ai restart
ai status
ai logs
ai shell
ai run
ai preview
```

### App

```bash
ai app stop
ai app restart
ai app status
ai app logs
```

### Harness

```bash
ai harness start
ai harness stop
ai harness restart
ai harness status
```

### DSH

```bash
ai dsh version
ai dsh update
ai dsh update <version>
```

### Maintenance

```bash
ai cache
ai cache clear
ai cache clear --deps
ai cache clear --deps --yes
ai update
ai upgrade
ai doctor
```

### GitHub

```bash
ai github setup
ai github status
ai github test
```

### Tunnel (anywhere access, optional)

```bash
ai tunnel setup
ai tunnel sync [port]
ai tunnel status
ai tunnel start
ai tunnel stop
ai tunnel logs
```

### State

```bash
ai state export
ai state import <archive>
```

---

## Project Lifecycle

```text
GitHub repository
       │
       ▼
ai add <github-url>
       │
       ▼
~/projects/project-name
       │
       ▼
ai use project-name
       │
       ▼
ACTIVE_PROJECT / ACTIVE_PROJECT_PATH
       │
       ▼
ai start
       │
       ▼
Docker workstation
       │
       ▼
ai run
       │
       ▼
Development server
       │
       ▼
ai preview
       │
       ▼
Mac browser through SSH tunnel
```

Switching projects reuses the same workstation image.

---

## Harness and DSH Lifecycle

DSH installation, DSH state, and Harness runtime metadata are deliberately separate.

```text
runtime/npm-global/
    └── DSH installation

runtime/dsh/
    └── DSH state/config/history

runtime/harness/
    └── PID/log/runtime metadata
```

Inside the container:

```text
DSH
 └── 127.0.0.1:4090
        ▲
        │
        │ local bridge
        │
Bridge
 └── 0.0.0.0:4091
        │
        ▼
Host: 127.0.0.1:4090
```

This lets the DSH service remain container-internal while still being reachable locally through an SSH tunnel.

---

## Preview and SSH Tunneling

Development ports are intentionally not public.

Current fixed host bindings include:

```text
127.0.0.1:3000
127.0.0.1:3001
127.0.0.1:5173
127.0.0.1:8080
127.0.0.1:8000
127.0.0.1:4090 -> container:4091
```

The project development server may use another port, such as `5173`.

Run:

```bash
ai preview
```

Example:

```text
Detected app port(s): 5173

SSH tunnel command:

ssh -N \
  -L 5173:172.20.0.2:5173 \
  -L 4090:172.20.0.2:4091 \
  mosabbir-cloud

URLs:
  App : http://127.0.0.1:5173
  DSH : http://127.0.0.1:4090
```

The container IP and app ports are runtime values and must not be hard-coded.

---

## Anywhere Access via Cloudflare Tunnel

SSH tunneling is the default (zero public attack surface). Cloudflare Tunnel is the opt-in path for using the app and DSH from anywhere without running SSH from your own machine. Everything is done in the Cloudflare dashboard.

Full guide (dashboard setup, route form, multi-app hostnames, troubleshooting): [docs/cloudflare-tunnel.md](docs/cloudflare-tunnel.md).

Quick reference (on the VPS):

```bash
ai tunnel setup
ai tunnel status
ai preview   # prints Anywhere URLs, flags any dashboard port edit
```

Result: `https://app.example.com` and `https://dsh.example.com`, each behind a Cloudflare Access policy.

> [!IMPORTANT]
> DSH's Settings pages (Models, Plugins) are loopback-only by upstream design: on any non-`localhost` address the browser client refuses to load them (`settings are unavailable in this browser`), and no server or tunnel setting changes that. Enter API keys **once** via the SSH address (`http://127.0.0.1:4090`, token from `ai preview`), then use the public URL for everything else (chat, sessions, workspaces). Details: [docs/cloudflare-tunnel.md](docs/cloudflare-tunnel.md#dsh-settings-are-loopback-only).

### Bind address (automatic)

`ai run` binds the dev server to `0.0.0.0` automatically so both SSH preview and the tunnel can reach it — no `package.json` edits needed:

- Vite / Astro / SvelteKit / Nuxt / Angular: appends `--host 0.0.0.0`.
- Next.js: appends `-H 0.0.0.0`.
- Your own `--host` / `-H` / `0.0.0.0` in the `dev` script always wins (never overridden).
- Backend apps (Express / Nest / Fastify / Hono / ...): no flag is injected. These bind all interfaces by default or respect the `HOST=0.0.0.0` environment the workstation already exports — just make sure the code does not hard-code `localhost` (use `process.env.HOST` when a host is specified).
- Non-JS backends (Python / Go / ...) are not started by `ai run`: bind `0.0.0.0` manually (Flask `--host=0.0.0.0`, uvicorn `--host 0.0.0.0`, Django `runserver 0.0.0.0:8000` plus `ALLOWED_HOSTS`).

`ai run` prints the active mode: `Bind: auto (--host 0.0.0.0)` or `Bind: project config`.

---

## Git Workflow

GitHub is the source of truth for project source.

Typical workflow:

```bash
ai use my-project
ai start
ai run

# develop

ai pull
ai push "feat: implement feature"

ai app stop
ai stop
```

The workstation does not require a PAT or host SSH private key mounted into the container.

---

## Cache Management

### Inspect

```bash
ai cache
```

This is read-only.

### Safe cleanup

```bash
ai cache clear
```

Cleans reclaimable Docker builder cache and npm cache when the workstation is running.

It does not intentionally remove:

- DSH state;
- DSH installation;
- `.env`;
- Git repositories;
- Docker images;
- Docker containers;
- Docker volumes.

### Dependency cleanup

```bash
ai cache clear --deps
```

Removes `node_modules` directories under `~/projects` after confirmation.

Non-interactive:

```bash
ai cache clear --deps --yes
```

Recommended:

```bash
ai app stop
ai cache clear --deps
ai run
```

Dependencies are reinstalled from the project's lockfile.

---

## State Backup and Recovery

Project source is protected by GitHub. DSH state is separate and should be backed up independently.

### Export

```bash
ai state export
```

Store state archives somewhere protected and preferably off-host.

### Import

```bash
ai state import <archive>
```

Only import trusted archives.

Recommended recovery flow:

```bash
ai stop
ai state import /path/to/backup.tar.gz
ai start
ai dsh version
```

### Backup recommendation

For a production/operator environment, use regular encrypted and off-host copies of state exports.

The current system provides export/import functionality; automatic offsite backup remains an operational responsibility.

---

## Updates and Upgrades

There are three separate update layers.

### CLI/repository

```bash
ai update
```

or:

```bash
./update.sh
```

### Workstation image

```bash
ai upgrade
```

The image is consumed from GHCR.

### DSH only

```bash
ai dsh update
```

Recommended DSH upgrade:

```bash
ai state export
ai dsh update
ai harness restart
ai dsh version
```

DSH updates do not require rebuilding the base image because the installation lives in persistent `runtime/npm-global`.

---

## CI/CD

The workstation image is built for Linux amd64 and arm64 in GitHub Actions.

```text
Push to main
     │
     ▼
.github/workflows/image.yml
     │
     ├── checkout
     ├── QEMU (multi-arch)
     ├── Docker Buildx
     ├── GHCR login
     ├── build linux/amd64,linux/arm64
     ├── push :latest
     ├── push :<commit-sha>
     ├── inspect published images
     └── clean old tagged versions
```

Published references:

```text
ghcr.io/mosabbir-maruf/ai-workstation-cli:latest
ghcr.io/mosabbir-maruf/ai-workstation-cli:<commit-sha>
```

### Why SHA tags?

`latest` is convenient. A commit SHA tag provides a deterministic image reference for rollback and debugging.

For controlled deployments:

```dotenv
IMAGE=ghcr.io/mosabbir-maruf/ai-workstation-cli:<commit-sha>
```

is preferable to relying only on `latest`.

---

## Operational Runbook

### Start of day

```bash
ai doctor
ai start
ai status
ai run
ai preview
```

### During development

```bash
ai status
ai app logs
ai harness status
ai shell
```

### Switch project

```bash
ai use another-project
ai run
ai preview
```

With a tunnel configured, `ai preview` also prints the Anywhere URLs and flags any dashboard port edit. No extra command.

### First-time anywhere access (one time)

Dashboard:

```text
Zero Trust -> Networks -> Tunnels -> Create tunnel (Cloudflared)
  -> copy the connector token
Tunnel -> Public hostnames -> Add (after connector is running):
  app.example.com -> http://127.0.0.1:<app-port>
  dsh.example.com -> http://127.0.0.1:4090
Zero Trust -> Access -> policy for both hostnames
```

VPS (connector install = Debian 64-bit on amd64 VPS, arm64-bit on ARM VPS):

```bash
ai tunnel setup
ai tunnel status
```

Verify:

```bash
ai run
ai preview
```

Open `https://app.example.com` and `https://dsh.example.com` from anywhere.

First API key entry (one time): DSH Settings pages only load on loopback, so enter keys via SSH once — Mac terminal `ssh -N -L 4090:<container-ip>:4091 <vps>` (IP from `ai preview`), then `http://127.0.0.1:4090` (+ token from `ai preview`) → Settings → Models → Apply. Daily use stays on the public URLs.

### New project with anywhere access (one time per project)

Dashboard: add one public hostname for the project:

```text
<project>.example.com -> http://127.0.0.1:<that project's port>
```

VPS: nothing tunnel-related to run. Daily switching stays:

```bash
ai use <project>
ai run
ai preview
```

### End of day

```bash
ai app stop
ai stop
```

### Before DSH upgrade

```bash
ai state export
ai dsh update
ai harness restart
ai dsh version
```

### Before major workstation changes

```bash
ai state export
ai doctor
```

---

## Troubleshooting

### Workstation is stopped

```bash
ai start
```

Then:

```bash
ai status
```

### DSH/Harness is stopped

```bash
ai harness status
ai harness restart
```

If the workstation itself is stopped:

```bash
ai start
```

### App fails to start

```bash
ai app status
ai app logs
```

If dependencies need a clean reinstall:

```bash
ai app stop
ai cache clear --deps
ai run
```

### GitHub authentication fails

```bash
ai github status
ai github test
```

Check the broker and GitHub App configuration.

Do not copy a PAT or host SSH private key into the workstation as a workaround.

If `ai github test` fails with `Algorithm 'RS256' could not be found`, the Python `cryptography` backend is missing. Fix: [docs/github-app-setup.md](docs/github-app-setup.md#troubleshooting).

### Tunnel fails or serves the wrong port

```bash
ai tunnel status
sudo journalctl -u cloudflared -n 50
ai preview
```

Common causes: public hostname missing in the dashboard tunnel, wrong app port after switching projects (`ai preview` prints the exact dashboard edit), connector token revoked (re-run `ai tunnel setup`), dev server blocking the public hostname (allow it in Vite/Next.js), or a missing Cloudflare Access policy.

### Preview fails

```bash
ai status
ai preview
```

Run the generated SSH command from the client machine and verify that the app is listening on the detected port.

### Image problems

```bash
docker image ls ghcr.io/mosabbir-maruf/ai-workstation-cli
ai doctor
```

For deterministic deployments, use a SHA-tagged image.

---

## Security Checklist

```text
[ ] SSH key authentication enabled
[ ] SSH password authentication disabled
[ ] Root SSH login disabled
[ ] Firewall defaults to deny incoming
[ ] Only required public ports are open
[ ] Workstation runs as non-root
[ ] Workstation is not privileged
[ ] ALL Linux capabilities are dropped
[ ] no-new-privileges is enabled
[ ] Host Docker socket is not mounted
[ ] Host ~/.ssh is not mounted
[ ] Host networking is not used
[ ] Only active project is mounted at /workspace
[ ] .env is not tracked
[ ] GitHub private key is not tracked
[ ] Cloudflare Tunnel token is not tracked
[ ] Cloudflare Access policy protects tunnel hostnames
[ ] DSH credentials are protected
[ ] GitHub authentication uses broker/App flow
[ ] Development ports are localhost-only
[ ] DSH state has a recovery backup
[ ] Image source is trusted
```

Run:

```bash
ai doctor
```

regularly.

---

## Design Decisions

### One workstation, many projects

Common tooling belongs in the image. Project source stays outside the image so a new project does not require a new image.

### Active-project-only mount

Only the selected repository is exposed to the workstation. This reduces accidental access to unrelated projects.

### Persistent DSH installation

DSH can be updated independently from the base workstation image.

### Persistent DSH state

DSH state is workflow data rather than disposable container state, so it lives outside the container.

### No Docker socket

Mounting `/var/run/docker.sock` would provide the container with access to the host Docker daemon and greatly increase the blast radius. This architecture deliberately avoids it.

### No host SSH keys

GitHub access is brokered instead of mounting `~/.ssh` into the workstation.

### Local-only development ports

Development servers should not accidentally become public services. SSH tunneling provides private operator access.

### Prebuilt multi-arch image

The production VPS consumes a prebuilt amd64/arm64 image instead of compiling the image locally.

---

## Quick Reference

```text
PROJECTS
  ai add <github-url>
  ai remove <project>
  ai list
  ai use <project>

GIT
  ai pull
  ai push "commit message"

WORKSTATION
  ai start
  ai stop
  ai restart
  ai status
  ai logs
  ai shell
  ai run
  ai preview

APP
  ai app stop
  ai app restart
  ai app status
  ai app logs

HARNESS
  ai harness start
  ai harness stop
  ai harness restart
  ai harness status

DSH
  ai dsh update [version]
  ai dsh version

MAINTENANCE
  ai cache
  ai cache clear
  ai cache clear --deps
  ai cache clear --deps --yes
  ai update
  ai upgrade
  ai doctor

GITHUB
  ai github setup
  ai github status
  ai github test

TUNNEL
  ai tunnel setup
  ai tunnel sync [port]
  ai tunnel status
  ai tunnel start
  ai tunnel stop
  ai tunnel logs

STATE
  ai state export
  ai state import <archive>
```

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on development workflow, branch naming, coding standards, shell scripting guidelines, and validation requirements before opening a pull request.

---

## Security

Security is foundational to AI Workstation. To report a security vulnerability or learn more about our container isolation boundaries, credential helper architecture, and defense-in-depth model, please consult [SECURITY.md](SECURITY.md).

---

## License

This project is licensed under the MIT License. See [LICENSE](https://github.com/mosabbir-maruf/ai-workstation-cli/blob/main/LICENSE) for the full license text.

---

## Maintainer

Developed and maintained by [**Mosabbir Maruf**](https://github.com/mosabbir-maruf).

[![GitHub Profile](https://img.shields.io/badge/GitHub-mosabbir--maruf-181717?style=flat&logo=github)](https://github.com/mosabbir-maruf)

---

## Maintainer Notes

This repository is the source of truth for the workstation infrastructure and operator tooling.

Keep the following out of Git:

- host runtime state;
- project working copies;
- `.env`;
- private keys;
- DSH credentials;
- temporary files;
- caches.

Use GitHub for project source and the state export mechanism for DSH/workstation recovery.
