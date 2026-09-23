# AI Workstation

> A reusable, isolated AI coding workstation for running DeepSeek Harness (DSH) and project development workloads on a remote Linux VPS.

[![Platform](https://img.shields.io/badge/platform-linux%2Farm64-informational)](https://github.com/mosabbir-maruf/ai-workstation)
[![Runtime](https://img.shields.io/badge/runtime-Docker-blue)](https://www.docker.com/)
[![AI Runtime](https://img.shields.io/badge/AI%20runtime-DeepSeek%20Harness-black)](https://github.com/deepseek-ai/deepseek-harness)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Contributing](https://img.shields.io/badge/contributions-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Security Policy](https://img.shields.io/badge/security-policy-red.svg)](SECURITY.md)
[![Maintainer](https://img.shields.io/badge/maintainer-Mosabbir%20Maruf-181717?logo=github)](https://github.com/mosabbir-maruf)

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
│  │ ~/projects/          │       │ ~/ai-workstation/                     │  │
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
│  │                            ai-workstation                            │  │
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
ai-workstation/
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
│   │   └── image.yml                # ARM64 GHCR build & publish workflow
│   └── pull_request_template.md     # PR submission template
│
├── broker/
│   └── github_broker.py             # Host-side GitHub App credential broker
│
├── config/
│   └── projects.yml                 # Project configuration registry
│
├── docker/
│   ├── Dockerfile                   # Base ARM64 workstation image
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
        └── github.sh                # GitHub App/broker helpers
```

> [!NOTE]
> `runtime/`, `.env`, `.venv/`, `secrets/`, and project checkouts under `~/projects/` are local host runtime paths and are intentionally excluded from version control.

---

## Host Runtime Structure

```text
~/
├── ai-workstation/
│   ├── .env
│   ├── .venv/
│   ├── runtime/
│   │   ├── dsh/
│   │   ├── npm-global/
│   │   ├── app/
│   │   ├── harness/
│   │   └── github-broker/
│   └── secrets/
│       └── github-app.pem
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
- ARM64 host for the current published image, or an appropriate image/build strategy.

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
git clone https://github.com/mosabbir-maruf/ai-workstation.git ~/ai-workstation
cd ~/ai-workstation
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
IMAGE=ghcr.io/mosabbir-maruf/ai-workstation:latest
DSH_VERSION=0.1.2-rc.1
ACTIVE_PROJECT=
ACTIVE_PROJECT_PATH=
```

The CLI also maintains GitHub App/broker-related values locally when configured.

### Rules

- Keep `.env` private.
- Never commit `.env`.
- Keep `secrets/github-app.pem` private.
- Prefer trusted/pinned image references for controlled deployments.
- Pin `DSH_VERSION` when deterministic behavior is required.

---

## GitHub Authentication

GitHub access is brokered through a GitHub App. No PAT or SSH private key is copied into the workstation container.

You need three values:

```text
GitHub App ID
GitHub Installation ID
GitHub App private key (.pem)
```

### 1. Create a GitHub App

1. On GitHub.com, go to Settings -> Developer settings -> GitHub Apps -> New GitHub App.
2. Fill in a name and Homepage URL (for example, `https://example.com`).
3. Disable Webhook if you do not need it.
4. Set minimum permissions, for example:
   - Contents: Read and write
   - Metadata: Read-only
   - Pull requests: Read and write
5. Create the App.
6. Note the `App ID` shown on the App general page.

### 2. Generate the private key

GitHub generates this key; do not create it locally with `openssl`.

1. On the App general page, select `Generate a private key`.
2. GitHub downloads a `.pem` file, for example:
   ```text
   ai-dev-workstation.2026-09-23.private-key.pem
   ```
3. The download happens only once. If you lose the file, return to the same page and generate a new private key. Generating a new key revokes the previous one.

The key must contain:

```text
-----BEGIN RSA PRIVATE KEY-----
...
-----END RSA PRIVATE KEY-----
```

or:

```text
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
```

### 3. Install the App and get the Installation ID

1. On the App page, select `Install App`.
2. Install it on your account or selected repositories.
3. After installation, copy the `Installation ID` from the installation URL:
   ```text
   https://github.com/settings/installations/<INSTALLATION_ID>
   ```

### 4. Copy the private key from your local machine to the VPS

`ai github setup` runs on the VPS and expects a VPS-local `.pem` path. Copy the downloaded file from your local machine first.

From your local machine:

```bash
ssh <user>@<vps-host> "mkdir -p ~/ai-workstation/secrets && chmod 700 ~/ai-workstation/secrets"

scp /path/to/<app-name>.<date>.private-key.pem \
  <user>@<vps-host>:~/ai-workstation/secrets/github-app.pem
```

Example:

```bash
scp "/Users/mosabbirmaruf/Downloads/ai-dev-workstation.2026-09-23.private-key.pem" \
  mosabbir-cloud:~/ai-workstation/secrets/github-app.pem
```

Alternatively, copy to a temporary VPS path and let setup install it:

```bash
scp "/Users/mosabbirmaruf/Downloads/ai-dev-workstation.2026-09-23.private-key.pem" \
  mosabbir-cloud:/tmp/github-app.pem
```

> [!NOTE]
> On macOS, if `scp` fails with `Operation not permitted` for a file under `~/Downloads`, macOS privacy is blocking Terminal from reading Downloads. Fix 1 (fastest, no settings change): move it with Finder.
>
> 1. Open Finder -> Downloads.
> 2. Copy `ai-dev-workstation.2026-09-23.private-key.pem`.
> 3. Paste it in your Home folder, for example to `~` or `~/.ssh/`.
> 4. Then from Terminal:
>
> ```bash
> chmod 600 ~/ai-dev-workstation.2026-09-23.private-key.pem
>
> scp ~/ai-dev-workstation.2026-09-23.private-key.pem \
>   mosabbir-cloud:~/ai-workstation/secrets/github-app.pem
> ```
>
> If you pasted to `~/.ssh/`, adjust the path accordingly. Do not use `cp` in Terminal to move it — the same block will hit. Use Finder drag/copy.

Then, on the VPS:

```bash
chmod 600 ~/ai-workstation/secrets/github-app.pem
ls -l ~/ai-workstation/secrets/github-app.pem
head -1 ~/ai-workstation/secrets/github-app.pem
```

The final private key belongs at:

```text
~/ai-workstation/secrets/github-app.pem
```

Protect it:

```bash
chmod 600 ~/ai-workstation/secrets/github-app.pem
```

### 5. Configure and test

On the VPS:

```bash
ai github setup
ai github status
ai github test
```

When `ai github setup` prompts for:

```text
Private key (.pem) path:
```

enter either:

```text
~/ai-workstation/secrets/github-app.pem
```

or, if you used the temporary-path method:

```text
/tmp/github-app.pem
```

Setup copies the key to `~/ai-workstation/secrets/github-app.pem`, saves the App and Installation IDs to `.env`, and starts the broker service.

A successful authentication test should report:

```text
Testing GitHub App credentials...
✓ GitHub Installation Token: OK

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

The workstation image is built for Linux ARM64 in GitHub Actions.

```text
Push to main
     │
     ▼
.github/workflows/image.yml
     │
     ├── checkout
     ├── QEMU ARM64
     ├── Docker Buildx
     ├── GHCR login
     ├── build linux/arm64
     ├── push :latest
     ├── push :<commit-sha>
     ├── inspect published images
     └── clean old tagged versions
```

Published references:

```text
ghcr.io/mosabbir-maruf/ai-workstation:latest
ghcr.io/mosabbir-maruf/ai-workstation:<commit-sha>
```

### Why SHA tags?

`latest` is convenient. A commit SHA tag provides a deterministic image reference for rollback and debugging.

For controlled deployments:

```dotenv
IMAGE=ghcr.io/mosabbir-maruf/ai-workstation:<commit-sha>
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

If `ai github test` fails with `Algorithm 'RS256' could not be found`, the Python `cryptography` backend is missing:

```bash
~/ai-workstation/.venv/bin/pip install "PyJWT[crypto]"
~/ai-workstation/.venv/bin/python -c 'from jwt.api_jws import PyJWS; PyJWS().get_algorithm_by_name("RS256"); print("RS256 OK")'
sudo systemctl restart ai-github-broker
ai github test
```

New installs get this automatically via `./install.sh`.

### Preview fails

```bash
ai status
ai preview
```

Run the generated SSH command from the client machine and verify that the app is listening on the detected port.

### Image problems

```bash
docker image ls ghcr.io/mosabbir-maruf/ai-workstation
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

### Prebuilt ARM64 image

The production VPS consumes a prebuilt ARM64 image instead of compiling the image locally.

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

This project is licensed under the MIT License. See [LICENSE](LICENSE) for the full license text.

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
