# Security Policy

## 1. Overview

The **AIWS** project prioritizes the defense-in-depth isolation of developer environments running on remote Linux servers. Because the workstation executes AI-assisted development tools, arbitrary project builds, and dependencies, security boundaries are designed to constrain the blast radius of untrusted code while avoiding credential leakage to the container runtime.

---

## 2. Supported Versions

Security fixes are actively provided for the following versions:

| Version / Branch | Supported | Notes |
|---|---|---|
| `main` branch | :white_check_mark: Yes | Active development branch |
| Latest release / tag | :white_check_mark: Yes | Current production deployment targets |
| Historical commits | :x: No | Please upgrade to the latest `main` or release |

---

## 3. Reporting a Vulnerability

If you discover a security vulnerability in AIWS, please report it privately.

### Preferred Reporting Mechanism

- **GitHub Private Vulnerability Reporting**: If available on the repository, submit a report via the **Security** tab under **Report a vulnerability**.
- **Maintainer Profile Contact**: If private vulnerability reporting is not enabled, contact the maintainer privately through the maintainer's GitHub profile ([Mosabbir Maruf](https://github.com/mosabbir-maruf)) before any public disclosure.

> [!IMPORTANT]
> **Do NOT use public GitHub issues or discussions** to disclose potential security vulnerabilities or unpatched exploits.

---

## 4. What NOT to Disclose Publicly

To protect users and operators of AIWS, never share the following in public issues, discussions, or pull requests:

- Zero-day exploits or unmitigated vulnerability reproduction steps.
- Real private keys (`*.pem`, `*.key`), API tokens, or webhook secrets.
- Real contents of `.env` files or host system configurations.
- Real IP addresses, internal hostnames, or production SSH credentials.

---

## 5. What Information a Report Should Contain

To help us triage and remediate the issue promptly, include:

1. **Vulnerability Type**: A description of the problem (e.g., path traversal, privilege escalation, credential leakage, socket permission bypass).
2. **Affected Component**: Specific file(s) and lines involved (e.g., `scripts/aiws`, `broker/github_broker.py`, `docker/compose.yml`).
3. **Environment Details**: Host OS distribution, Docker version, Docker Compose version, architecture (`linux/arm64`), and DSH version.
4. **Step-by-Step Proof of Concept (PoC)**: Minimal, sanitized steps or script to reproduce the vulnerability.
5. **Impact Assessment**: What an attacker or compromised container workload could achieve.
6. **Suggested Remediation**: (Optional) Proposed patch or configuration fix.

---

## 6. Expected Response Process

When a report is received:

1. **Acknowledgment**: We aim to acknowledge receipt of the vulnerability report within **48 hours**.
2. **Triage and Verification**: The maintainer will investigate the report, confirm the vulnerability, and assess the severity within **5 business days**.
3. **Remediation**: A security patch will be developed in a private branch.
4. **Validation and Release**: The patch will be tested, merged, and published in an updated release or commit on `main`.
5. **Coordinated Disclosure**: An advisory will be published acknowledging the reporter (unless anonymity is requested) following patch availability.

---

## 7. Security Scope

The following areas are in-scope for security reviews:

- **Host CLI (`scripts/aiws`)**: Command execution, environment variable handling, path validation, and sanitization routines.
- **Broker Daemon (`broker/github_broker.py`)**: Socket creation, permission handling (`0660`), request parsing, JWT generation, and token delivery.
- **Container Isolation (`docker/compose.yml`, `docker/Dockerfile`)**: User separation, capability configuration, mount scope, and resource constraints.
- **State Export/Import (`cmd_state_export`, `cmd_state_import`)**: Archive inspection, path traversal protection, symlink validation, and hardlink prevention.
- **Credential Helpers**: In-container and host-side credential helper socket communication.

---

## 8. Threat Model and Security Boundaries

The system enforces four distinct operational boundaries:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. Host Management Layer                                                    │
│    - Host OS (Ubuntu), Docker daemon, sudoers, scripts/aiws, host user        │
│    - Host-only secrets: .env, secrets/github-app.pem                        │
├─────────────────────────────────────────────────────────────────────────────┤
│ 2. Workstation Container                                                    │
│    - Non-root user 'sandbox' (UID 1001)                                     │
│    - No Docker socket, no host ~/.ssh, cap_drop: ALL, no-new-privileges     │
│    - Mounts ONLY active project at /workspace                               │
├─────────────────────────────────────────────────────────────────────────────┤
│ 3. GitHub Credential Broker                                                 │
│    - Host-side systemd service with strict sandboxing                       │
│    - Communicates strictly via Unix domain socket (github.sock)             │
│    - Issues short-lived installation access tokens in memory                │
├─────────────────────────────────────────────────────────────────────────────┤
│ 4. Network and External Boundary                                            │
│    - Development ports bound to 127.0.0.1 on host (never 0.0.0.0)          │
│    - Private operator access via SSH port-forwarding tunnels                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 9. Container Security Assumptions

The workstation container runs untrusted dependencies (e.g., `npm install`, project development servers, AI coding agents). The container runtime in `docker/compose.yml` enforces:

- **Non-Root Execution**: Runs strictly as user `sandbox` (UID `1001`, GID `1001`).
- **Dropped Capabilities**: `cap_drop: [ALL]`. No Linux capabilities are retained.
- **No Privilege Escalation**: `security_opt: [no-new-privileges:true]`. Prevents `setuid` binaries from gaining elevated privileges.
- **Unprivileged Runtime**: `privileged: false`.
- **Resource Constraints**:
  - Memory: `512m` hard limit.
  - CPU: `1.5` CPUs.
  - PIDs: `256` maximum processes to mitigate fork bombs.
- **Secure `/tmp`**: Mounted as a `tmpfs` with `rw,noexec,nosuid,size=128m` to prevent execution of downloaded binaries in `/tmp`.
- **No Host Docker Socket**: `/var/run/docker.sock` is **never** mounted into the container, preventing container escapes to the host daemon.
- **No Host SSH Keys**: The host's `~/.ssh` directory is **never** mounted into the container.
- **Isolated Workspace**: Only the selected active project directory is mounted at `/workspace`. Unselected projects under `~/projects/` are inaccessible.

---

## 10. Credential Handling

### GitHub App Authentication Flow

Instead of storing long-lived Personal Access Tokens (PATs) or SSH private keys inside the workstation, authentication is brokered:

1. When Git inside the container initiates an HTTPS operation with `github.com`, the container-side helper (`/usr/local/bin/github-app-credential-helper`) is invoked with `get`.
2. The helper connects to the Unix socket `/run/ai-github-broker/github.sock`.
3. The host-side broker receives the request, validates the protocol and host (`github.com`), generates an RS256 JWT using `secrets/github-app.pem`, and requests a short-lived installation token from GitHub.
4. The broker returns the token to the socket connection.
5. The credential helper passes the token via `stdout` to Git in-memory.
6. The credential helper deliberately ignores `store` and `erase` actions, ensuring tokens are **never written to disk** inside the container.

### Sensitive File Pre-Commit Guardrail

The CLI command `aiws push` performs automated pre-commit scanning on staged files before creating a commit. It aborts if sensitive filenames match patterns such as:
- `.env` or `.env.*` (excluding `.env.example`)
- `*.pem`, `*.key`, `*.p12`, `*.pfx`
- `credentials.json`, `service-account*.json`

---

## 11. GitHub App and Broker Security

The host-side broker (`broker/github_broker.py`) runs as a dedicated systemd service (`ai-github-broker`) with host-level hardening:

- `NoNewPrivileges=true`
- `PrivateTmp=true`
- `ProtectSystem=strict`
- `ProtectHome=read-only`
- `ReadWritePaths=$RUNTIME_DIR`

Socket permissions:
- Directory `runtime/github-broker` is owned by `<user>:ai-broker` with mode `770`.
- Socket `github.sock` is created with mode `0660`.
- The workstation container joins group `ai-broker` via `group_add: ["${GITHUB_BROKER_GID:-987}"]` to allow communication with the socket.
- The broker requires a valid GitHub App private key (`secrets/github-app.pem`) with mode `600`, which is inaccessible to the container.

---

## 12. Secret Handling

Host operators must observe the following secret handling standards:

| Path | Purpose | Recommended Mode | Storage Location |
|---|---|---|---|
| `.env` | Environment configuration | `0600` | Host repository root |
| `secrets/` | Secret storage directory | `0700` | Host repository root |
| `secrets/github-app.pem` | GitHub App private key | `0600` | Host `secrets/` directory |
| `secrets/cloudflared-token` | Cloudflare Tunnel token | `0600` | Host `secrets/` directory |
| `runtime/dsh/.credentials.yaml` | DSH API credentials | `0600` | Host persistent runtime |
| `WORKSTATION_API_KEY` | Web Console daemon token | (secret string) | Stored inside `.env` (`0600`) |

Secrets must **never** be checked into version control.

---

## 13. Host Control Daemon & Docker Security

- **Host Daemon Authentication**: When the web control daemon (`aiws daemon`) is exposed via reverse proxy or Cloudflare Tunnel, `WORKSTATION_API_KEY` must be configured in `.env`. All incoming requests require valid Bearer token authorization verified via constant-time comparison (`secrets.compare_digest`). Unauthenticated requests are rejected with `401 Unauthorized` before executing system calls.
- **Host Daemon Protection**: Access to the host Docker daemon should be restricted to administrative users.
- **Trusted Images**: Use pinned images (`IMAGE=ghcr.io/mosabbir-maruf/aiws-cli:<commit-sha>`) in production environments rather than mutable `latest` tags.
- **Local Port Bindings**: Ports configured in `compose.yml` (`3000`, `3001`, `8000`, `4090:4091`) must always bind to `127.0.0.1` on the host, never `0.0.0.0`.

---

## 14. State Export and Import Security

The `aiws state export` and `aiws state import` commands back up and restore DSH workflow state. Because archive extraction presents path traversal and execution risks, the import process enforces:

1. **Archive Content Validation**: Rejects archives containing files outside `manifest`, `.env`, and `dsh/*`.
2. **Path Traversal Checks**: Rejects absolute paths (`/*`) and relative traversal elements (`../`, `*/../*`).
3. **Symlink Target Sanitization**: Validates all staged symlinks. Symlinks targeting paths outside `/home/sandbox/.npm-global/*` or containing relative traversal (`..`) are rejected.
4. **Hardlink Prohibition**: Archives containing hardlinks are strictly rejected.
5. **Staging Isolation**: Archives are extracted into a temporary directory created via `mktemp -d` using `--no-same-owner` and `--no-same-permissions`.
6. **Automatic Rollback Backup**: Before modifying runtime files, the existing `.env` and `runtime/dsh` are backed up to temporary locations.

Operators should only import state archives from trusted, verified sources.

---

## 15. Responsible Disclosure

We believe in responsible, coordinated disclosure:

- Reporters are requested to give maintainers a reasonable window (typically **30 to 90 days** depending on complexity) to patch and release a fix before public disclosure.
- We will keep the reporter informed of remediation progress.
- Public credit will be given in the release notes upon disclosure, unless the reporter requests anonymity.

---

## 16. Security Limitations and Out-of-Scope Areas

While AIWS implements robust defense-in-depth, operators should understand its inherent boundaries:

- **Container vs. Hypervisor Isolation**: Docker containers share the host Linux kernel. Container isolation does not provide the same hard boundary as a Type-1 or Type-2 hypervisor against kernel-level privilege escalation (e.g., zero-day kernel vulnerabilities).
- **Compromised Host User**: If an attacker gains root or host user access on the VPS, all security boundaries are compromised.
- **Malicious Code in Active Project**: The workstation container allows the active project to execute node/npm scripts. Malicious packages within `/workspace` can consume allocated container resources or read files within the active project directory.
- **Third-Party Package Ecosystem**: Vulnerabilities in upstream packages (such as Node.js, DeepSeek Harness, npm packages, or Linux packages) are out of scope unless they stem from AIWS's integration.

