#!/usr/bin/env python3

import json
import os
import socket
import time
from pathlib import Path
from urllib.request import Request, urlopen

import jwt


def _resolve_root() -> Path:
    env_root = os.environ.get("AIWS_ROOT")
    if env_root:
        p = Path(env_root).resolve()
        if p.is_dir() and (p / "broker/github_broker.py").is_file():
            return p
    return Path(__file__).resolve().parent.parent


ROOT = _resolve_root()
ENV_FILE = ROOT / ".env"
PRIVATE_KEY = ROOT / "secrets/github-app.pem"
SOCKET_PATH = ROOT / "runtime/github-broker/github.sock"

GITHUB_API = "https://api.github.com"
GITHUB_API_VERSION = "2026-03-10"

_token = None
_token_expires_at = 0


def load_env():
    values = {}

    if not ENV_FILE.is_file():
        return values

    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()

        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        values[key] = value

    return values


def get_config():
    env = load_env()

    app_id = os.environ.get("GITHUB_APP_ID") or env.get("GITHUB_APP_ID")
    installation_id = (
        os.environ.get("GITHUB_INSTALLATION_ID")
        or env.get("GITHUB_INSTALLATION_ID")
    )

    if not app_id:
        raise RuntimeError("GITHUB_APP_ID is not configured.")

    if not installation_id:
        raise RuntimeError(
            "GITHUB_INSTALLATION_ID is not configured."
        )

    return app_id, installation_id


def create_app_jwt():
    app_id, _ = get_config()

    if not PRIVATE_KEY.is_file():
        raise RuntimeError(f"Private key not found: {PRIVATE_KEY}")

    private_key = PRIVATE_KEY.read_text().strip()
    if not private_key:
        raise RuntimeError(f"Private key is empty: {PRIVATE_KEY}")

    now = int(time.time())

    payload = {
        "iat": now - 60,
        "exp": now + 540,
        "iss": app_id,
    }

    return jwt.encode(
        payload,
        private_key,
        algorithm="RS256",
    )


def get_installation_token():
    global _token
    global _token_expires_at

    now = int(time.time())

    if _token and now < _token_expires_at - 300:
        return _token

    _, installation_id = get_config()

    app_jwt = create_app_jwt()

    url = (
        f"{GITHUB_API}/app/installations/"
        f"{installation_id}/access_tokens"
    )

    request = Request(
        url,
        method="POST",
        headers={
            "Authorization": f"Bearer {app_jwt}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": GITHUB_API_VERSION,
            "User-Agent": "AI-Dev-Workstation",
        },
    )

    with urlopen(request, timeout=15) as response:
        data = json.loads(response.read())

    token = data.get("token")
    expires_at = data.get("expires_at")

    if not token:
        raise RuntimeError(
            "GitHub did not return an installation token."
        )

    _token = token

    if expires_at:
        try:
            expires_struct = time.strptime(
                expires_at,
                "%Y-%m-%dT%H:%M:%SZ",
            )

            _token_expires_at = int(
                time.mktime(expires_struct)
            )
        except ValueError:
            _token_expires_at = now + 3600
    else:
        _token_expires_at = now + 3600

    return _token


def handle_request(request):
    request = request.strip()

    if not request:
        return ""

    fields = {}

    for line in request.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key] = value

    if fields.get("protocol") != "https":
        return ""

    if fields.get("host") != "github.com":
        return ""

    token = get_installation_token()

    return (
        "protocol=https\n"
        "host=github.com\n"
        "username=x-access-token\n"
        f"password={token}\n\n"
    )


def main():
    SOCKET_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    try:
        SOCKET_PATH.unlink()
    except FileNotFoundError:
        pass

    server = socket.socket(
        socket.AF_UNIX,
        socket.SOCK_STREAM,
    )

    server.bind(str(SOCKET_PATH))

    os.chmod(SOCKET_PATH, 0o660)

    server.listen(8)

    if not PRIVATE_KEY.is_file():
        print(
            f"GitHub broker listening on {SOCKET_PATH} (warning: private key {PRIVATE_KEY} not configured yet)",
            flush=True,
        )
    else:
        print(
            f"GitHub broker listening on {SOCKET_PATH}",
            flush=True,
        )

    while True:
        connection, _ = server.accept()

        try:
            chunks = []

            while True:
                data = connection.recv(4096)

                if not data:
                    break

                chunks.append(data)

                if b"\n\n" in data:
                    break

            request = b"".join(chunks).decode(
                "utf-8",
                errors="replace",
            )

            response = handle_request(request)

            connection.sendall(
                response.encode("utf-8")
            )

        except Exception as exc:
            print(
                f"Broker request failed: {exc}",
                flush=True,
            )

        finally:
            connection.close()


if __name__ == "__main__":
    main()
