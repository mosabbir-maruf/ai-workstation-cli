# Contributing to AIWS

Thank you for your interest in contributing to **AIWS**.

AIWS is a reusable, isolated AI coding workstation designed for running DeepSeek Harness (DSH) and project development workloads on a remote Linux VPS. The project combines host-level process orchestration, container isolation, and a brokered GitHub App credential architecture.

We welcome contributions that improve stability, security, documentation, and operator ergonomics while preserving the project's core isolation boundaries.

---

## Table of Contents

1. [Before You Start](#1-before-you-start)
2. [Development Environment](#2-development-environment)
3. [Repository Structure](#3-repository-structure)
4. [Development Workflow](#4-development-workflow)
5. [Branch Naming](#5-branch-naming)
6. [Commit Message Convention](#6-commit-message-convention)
7. [Code Guidelines](#7-code-guidelines)
8. [Shell Scripting Guidelines](#8-shell-scripting-guidelines)
9. [Docker Guidelines](#9-docker-guidelines)
10. [Configuration Guidelines](#10-configuration-guidelines)
11. [Testing and Validation](#11-testing-and-validation)
12. [Security-Sensitive Change Testing](#12-security-sensitive-change-testing)
13. [Pull Request Requirements](#13-pull-request-requirements)
14. [PR Description Expectations](#14-pr-description-expectations)
15. [Review Process](#15-review-process)
16. [Documentation Requirements](#16-documentation-requirements)
17. [Bug Reporting](#17-bug-reporting)
18. [Feature Requests](#18-feature-requests)
19. [Questions and Discussions](#19-questions-and-discussions)
20. [Contributor Checklist](#20-contributor-checklist)

---

## 1. Before You Start

Before making changes, familiarize yourself with the four foundational boundaries of AIWS:

1. **Host Management Layer**: The `aiws` CLI (`scripts/aiws`), Python virtual environment, project checkouts under `~/projects/`, and host runtime files (`runtime/`, `secrets/`, `.env`).
2. **Workstation Container**: An isolated, unprivileged Docker container running as non-root `sandbox` (UID `1001`) with all Linux capabilities dropped, strict resource limits (512 MB RAM, 1.5 CPUs, 256 PIDs), and only the active project mounted at `/workspace`.
3. **GitHub Broker**: A host-side daemon (`broker/github_broker.py`) communicating over a dedicated Unix domain socket (`runtime/github-broker/github.sock`) that mints short-lived GitHub App tokens on demand, completely eliminating the need to mount SSH private keys or Personal Access Tokens (PATs) inside the container.
4. **Network and Preview Boundary**: Development ports are bound to `127.0.0.1` on the host and accessed via SSH port-forwarding rather than exposed publicly.

Any proposed change that weakens these isolation boundaries will be rejected.

---

## 2. Development Environment

### Prerequisites

To develop and test AIWS locally or on a remote test server, ensure you have:

- **Operating System**: Linux (Ubuntu 22.04/24.04 recommended) or macOS for local scripting and review. Full end-to-end container testing requires Linux (specifically Linux ARM64 for published images, or local Docker build capability).
- **Docker Engine**: Docker 24.0+ with Docker Compose support (`docker compose` v2).
- **Bash**: Version 4.0 or newer.
- **Python**: Version 3.10+ with `venv` support (`python3-venv`).
- **Git**: Version 2.30+.
- **Node.js & npm**: Node.js 22 LTS (used inside the container and for credential helpers).
- **System Utilities**: `tini`, `ripgrep`, `fd-find`, `procps`, `ca-certificates`.

### Local vs. Remote Testing

- **Script & Syntax Verification**: Can be performed locally on macOS or Linux without running containers.
- **Runtime & Integration Testing**: Must be executed on a dedicated Linux VPS or virtual machine to ensure accurate Docker volume, cgroup limits, and systemd behavior. Never test experimental branch code on your production workstation host.

---

## 3. Repository Structure

```text
aiws-cli/
├── .env.example                     # Environment template
├── .gitignore                       # Ignored secrets, runtime, and OS files
├── CONTRIBUTING.md                  # Contributor guidelines (this file)
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
│   ├── Dockerfile                   # Base Node 22 slim ARM64 image
│   ├── compose.yml                  # Container definition, mounts, limits
│   ├── entrypoint.sh                # Container initialization & DSH setup
│   ├── app-runner.sh                # Detached background project runner
│   ├── harness.sh                   # DSH service & internal bridge controller
│   └── github-app-credential-helper # In-container Git credential helper
│
└── scripts/
    ├── aiws                           # Main operator CLI
    ├── github-app-credential-helper # Host-side Git credential helper
    └── lib/
        └── github.sh                # GitHub App setup and management library
```

### Runtime Directories (Excluded from Git)

The following paths are created on the host during installation and runtime. They must **never** be checked into Git:

- `.env`: Host environment configuration (permissions `600`).
- `.venv/`: Python virtual environment with `PyJWT`.
- `secrets/`: Host-only secrets, specifically `secrets/github-app.pem` (permissions `600`).
- `runtime/dsh/`: Persistent DeepSeek Harness settings and history (permissions `700`).
- `runtime/npm-global/`: Persistent npm modules including DSH installation (permissions `700`).
- `runtime/app/`: Ephemeral PID files and application logs for `aiws run`.
- `runtime/harness/`: Ephemeral PID files and logs for DSH and the bridge.
- `runtime/github-broker/`: Unix domain socket `github.sock` (permissions `770`, group `ai-broker`).
- `~/projects/`: Host Git checkouts of managed projects.

---

## 4. Development Workflow

1. **Fork and Clone**:
   ```bash
   git clone https://github.com/<your-username>/aiws-cli.git
   cd aiws-cli
   ```

2. **Create a Feature Branch**:
   ```bash
   git switch -c feat/my-improvement
   ```

3. **Make Focused Changes**: Keep changes minimal, modular, and directly related to the task.

4. **Validate Locally**: Run syntax checks, linter checks, and integration tests (see [Testing and Validation](#11-testing-and-validation)).

5. **Review Git Status and Diff**:
   ```bash
   git status --short
   git diff --check
   ```
   Ensure no untracked secrets, `.env` files, or whitespace issues exist.

6. **Commit with Conventional Messages**:
   ```bash
   git commit -m "feat(cli): add diagnostic flag to aiws doctor"
   ```

7. **Push and Open a Pull Request**:
   ```bash
   git push origin feat/my-improvement
   ```

---

## 5. Branch Naming

Use descriptive branch names with lower-case letters and hyphens:

- `feat/<feature-name>`: New capabilities or enhancements
- `fix/<issue-name>`: Bug fixes
- `docs/<topic>`: Documentation changes
- `refactor/<area>`: Code cleanup without behavior changes
- `test/<area>`: Test additions or validation improvements
- `chore/<task>`: Dependency updates, CI/CD tweaks, or maintenance

*Examples*: `feat/health-check-timeout`, `fix/broker-socket-permissions`, `docs/tunnel-preview`

---

## 6. Commit Message Convention

We follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

```text
<type>(<optional scope>): <short description in imperative mood>

[optional body explaining motivation and non-obvious details]

[optional footer(s), e.g., Closes #123]
```

### Allowed Types

- `feat`: A new feature or capability
- `fix`: A bug fix
- `docs`: Documentation only changes
- `refactor`: Code change that neither fixes a bug nor adds a feature
- `test`: Adding or correcting tests/validation scripts
- `chore`: Maintenance, repository setup, or housekeeping

### Examples

- `feat(cli): add json output option to aiws list`
- `fix(broker): handle socket reconnection on timeout`
- `docs(readme): clarify ssh preview port forward examples`
- `chore(deps): bump PyJWT to latest patch version`

---

## 7. Code Guidelines

- **Simplicity**: Write straightforward, maintainable code. Avoid complex abstractions where simple functions suffice.
- **No Extraneous Dependencies**: Do not add external Python packages, npm packages, or Linux packages without prior discussion.
- **Defensive Design**: Validate all user inputs, paths, and external commands before execution.
- **Clear Error Output**: Output informative error messages to `stderr` and exit with non-zero status codes using `die "..."`.

---

## 8. Shell Scripting Guidelines

All shell scripts (`scripts/aiws`, `install.sh`, `update.sh`, `docker/*.sh`, `scripts/lib/*`) must adhere to:

1. **Strict Mode**: Begin every bash script with:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   ```
2. **Defensive Quoting**: Quote all variable references (`"$var"` instead of `$var`) to prevent word splitting and glob expansion.
3. **Command Checks**: Use `command -v <tool> >/dev/null 2>&1` instead of `which`.
4. **Path Handling**: Use `cd "$(dirname "${BASH_SOURCE[0]}")" && pwd` to compute absolute script paths. Never rely on the caller's current working directory.
5. **Standard Functions**: Use the existing `die()` helper for fatal termination:
   ```bash
   die() {
       echo "ERROR: $*" >&2
       exit 1
   }
   ```
6. **Syntax Validation**: Every modified script must pass:
   ```bash
   bash -n <script-path>
   ```

---

## 9. Docker Guidelines

1. **Non-Root Execution**: The workstation container must run as the `sandbox` user (UID `1001`). Never add `sudo` or grant root privileges inside the container.
2. **Capability Dropping**: Do not add capabilities. `compose.yml` strictly enforces:
   ```yaml
   cap_drop:
     - ALL
   security_opt:
     - no-new-privileges:true
   privileged: false
   ```
3. **Resource Guardrails**: Changes to memory (`mem_limit`), CPU allocation (`cpus`), or process limits (`pids_limit`) must be justified by workload requirements.
4. **Multi-Architecture**: The base image is built for `linux/arm64`. When adding dependencies in `docker/Dockerfile`, ensure packages are available on ARM64 Debian Bookworm.
5. **Signal Handling**: Long-running container processes must run through `/usr/bin/tini` to properly reap zombies and handle `SIGTERM`.

---

## 10. Configuration Guidelines

1. **Environment Variables**:
   - New environment variables must be declared in `.env.example` with clear comments.
   - Do not assume variables are always present in the environment; provide defaults using `${VAR:-default}`.
2. **Never Commit Secrets**:
   - Never commit `.env` or any file containing tokens, passwords, or keys.
   - The `.gitignore` file enforces exclusion of sensitive patterns.
3. **Persistence Contracts**:
   - Container `/workspace` mounts the active project only (`ACTIVE_PROJECT_PATH`).
   - Host `runtime/dsh` mounts to `/home/sandbox/.dsh`.
   - Host `runtime/npm-global` mounts to `/home/sandbox/.npm-global`.
    - Host `runtime/app` mounts to `/run/aiws-cli/app`.
    - Host `runtime/harness` mounts to `/run/aiws-cli/harness`.
   - Host `runtime/github-broker` mounts to `/run/ai-github-broker`.

---

## 11. Testing and Validation

AIWS uses pragmatic shell and integration checks rather than heavy testing frameworks. Contributors must test their changes against the relevant subsystem:

### 1. Static and Syntax Checks

Always run syntax verification before submitting a PR:

```bash
# Validate all bash scripts
bash -n install.sh update.sh scripts/aiws scripts/lib/github.sh docker/*.sh docker/github-app-credential-helper

# Validate Python scripts
python3 -m py_compile broker/github_broker.py scripts/github-app-credential-helper

# Validate Docker Compose configuration
docker compose -f docker/compose.yml config

# Check for trailing whitespace and git formatting errors
git diff --check
```

### 2. CLI Validation (`scripts/aiws`)

If you modified `scripts/aiws`:
- Verify command dispatch and help outputs:
  ```bash
  aiws help
  aiws list
  aiws status
  aiws doctor
  ```
- Test project switching (`aiws use <project>`) and ensure the `/workspace` mount updates correctly.
- Test cache inspection (`aiws cache`) and dry-run/safe cache cleanup (`aiws cache clear`).

### 3. Docker Runtime Validation (`docker/*`)

If you modified `docker/Dockerfile` or `docker/compose.yml`:
- Validate image build:
  ```bash
  docker build -f docker/Dockerfile -t aiws-cli:test .
  ```
- Verify container startup and permissions:
  ```bash
  aiws start
  aiws status
  aiws shell
  # Inside container:
  id -u           # Must be 1001 (sandbox)
  dsh --version   # Must output version
  ```

### 4. Harness and DSH Validation

If you modified `docker/harness.sh` or DSH lifecycle routines:
- Verify Harness start, status, and stop:
  ```bash
  aiws harness status
  aiws harness restart
  aiws harness status
  ```
- Check DSH version output:
  ```bash
  aiws dsh version
  ```

### 5. GitHub Broker and Credential Flow

If you modified `broker/github_broker.py`, `scripts/lib/github.sh`, or credential helpers:
- Verify broker status and connectivity:
  ```bash
  aiws github status
  aiws github test
  ```
- Verify in-container credential helper execution by testing a Git operation (e.g., `git ls-remote` or `aiws pull`).
- Verify Unix socket permissions (`0660` or `0770` with group `ai-broker`).

### 6. State Import and Export

If you modified `cmd_state_export` or `cmd_state_import`:
- Run an export:
  ```bash
  aiws state export
  ```
- Verify the exported archive structure and permissions:
  ```bash
  tar -ztvf ~/aiws-state-backups/aiws-state-*.tar.gz
  ```
- Verify archive security validation by testing import against a valid export:
  ```bash
  aiws state import ~/aiws-state-backups/aiws-state-*.tar.gz
  ```

### 7. App Runner and Preview

If you modified `docker/app-runner.sh`, `cmd_run`, or `cmd_preview`:
- Start the application in an active project:
  ```bash
  aiws run
  aiws app status
  aiws app logs
  ```
- Verify port detection and SSH tunnel string generation:
  ```bash
  aiws preview
  ```
- Stop the application and verify process cleanup:
  ```bash
  aiws app stop
  aiws app status
  ```

---

## 12. Security-Sensitive Change Testing

Changes touching the following areas are classified as **Security-Sensitive**:

- Docker container capabilities, privileges, or security options (`compose.yml`).
- Volume mount additions or modifications.
- GitHub App authentication, JWT minting, or broker socket communication (`broker/github_broker.py`, `scripts/lib/github.sh`).
- State archive import validation logic (`cmd_state_import`).
- Pre-commit sensitive file detection in `aiws push`.
- User permissions, group memberships, or file mode settings (`chmod`, `chown`).

### Additional Requirements for Security Changes:
1. **Explain Threat Implications**: Document what threats were considered and how isolation is maintained.
2. **Negative Testing**: Provide evidence of testing failure paths (e.g., attempting path traversal in state import, verifying unauthorized socket access is rejected).
3. **Review Flag**: Explicitly mention in the PR title or description: `[Security] <summary>`.

---

## 13. Pull Request Requirements

Before opening a pull request, ensure:

- The PR targets the `main` branch.
- The PR is focused on a single logical change or feature.
- All syntax checks pass (`bash -n`, `py_compile`, `compose config`).
- Relevant manual or integration validation has been completed.
- `git diff --check` reports zero whitespace or formatting warnings.
- Documentation in `README.md` is updated to reflect any CLI or configuration changes.
- The `.github/pull_request_template.md` is completely filled out.
- **No secrets, tokens, private keys, `.env` files, or runtime data are included in commits**.

---

## 14. PR Description Expectations

A good PR description contains:

1. **Summary**: A concise description of the change.
2. **Motivation**: Why this change is necessary (reference existing issues if applicable).
3. **Changes**: Bulleted breakdown of modified components.
4. **Validation**: The exact commands executed and their output.
5. **Security Assessment**: Impact on container isolation and credential safety.
6. **Breaking Changes**: Any migration steps required for existing installations.

---

## 15. Review Process

1. **Initial Triage**: Maintainers review the PR for architectural alignment and security boundary adherence.
2. **Review Turnaround**: Reviews are typically conducted within 3–5 business days.
3. **Feedback and Iteration**: Address review comments by pushing updates to the same branch. Avoid force-pushing over unreviewed discussions if possible.
4. **Merge**: Once approved and all checks pass, the PR will be merged via squash-and-merge or fast-forward merge.

---

## 16. Documentation Requirements

- Any new CLI subcommands or options added to `scripts/aiws` must be documented in:
  - The CLI `usage()` function in `scripts/aiws`.
  - The CLI Reference section in `README.md`.
  - The Quick Reference table in `README.md`.
- Ensure Markdown formatting follows standard GitHub Flavored Markdown (GFM).
- Keep ASCII architecture diagrams accurately aligned.

---

## 17. Bug Reporting

If you encounter a bug, submit an issue using our [Bug Report Form](https://github.com/mosabbir-maruf/aiws-cli/issues/new?template=bug_report.yml).

Provide:
- A clear description of the problem.
- Your environment details (Host OS, Docker version, architecture).
- Workstation version or Git commit SHA.
- The exact `aiws` command executed.
- Sanitized reproduction steps.
- Sanitized `aiws doctor` output.

> [!CAUTION]
> **Never include secrets in bug reports**: Redact private keys, tokens, `.env` entries, passwords, or internal server IPs before submitting.

---

## 18. Feature Requests

To suggest a new feature or improvement, open an issue using our [Feature Request Form](https://github.com/mosabbir-maruf/aiws-cli/issues/new?template=feature_request.yml).

Good feature proposals:
- Solve a real operational problem for remote AI development.
- Respect the existing security and container isolation boundaries.
- Avoid adding unnecessary runtime complexity or third-party dependencies.

---

## 19. Questions and Discussions

For general questions, configuration assistance, or architectural discussions:
- Review existing documentation in `README.md`.
- Open a discussion or inquiry on GitHub.
- For sensitive security inquiries, follow the process in `SECURITY.md`.

---

## 20. Contributor Checklist

Before submitting your pull request, verify each item:

- [ ] I have read and followed the guidelines in `CONTRIBUTING.md`.
- [ ] My changes are focused and atomic.
- [ ] All shell scripts pass `bash -n`.
- [ ] All Python scripts pass `python3 -m py_compile`.
- [ ] Docker Compose config validates (`docker compose -f docker/compose.yml config`).
- [ ] `git diff --check` passes with no whitespace errors.
- [ ] `aiws doctor` passes if testing on a live workstation environment.
- [ ] No secrets, private keys, `.env` files, or runtime state are committed.
- [ ] Documentation in `README.md` has been updated where appropriate.
- [ ] Any breaking changes or operational requirements are documented.
