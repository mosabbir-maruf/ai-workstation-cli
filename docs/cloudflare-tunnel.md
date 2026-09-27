# Anywhere Access via Cloudflare Tunnel

SSH tunneling is the default (zero public attack surface). Cloudflare Tunnel is the opt-in path for using the app and DSH from anywhere without running SSH from your own machine. Everything is done in the Cloudflare dashboard — no CLI login, no certificate files, no JSON to copy.

How it stays fast and safe:

- `cloudflared` runs on the VPS host, not inside the 512 MB workstation container, so it adds no container memory/CPU pressure.
- The origin is always local (`http://127.0.0.1:<port>`), so there is no extra network hop and no dependency on the changing container IP.
- One persistent connector (QUIC) serves all hostnames instead of one connection per request.
- Development ports stay bound to `127.0.0.1`; Cloudflare is the only ingress. Every hostname must sit behind a Cloudflare Access policy.

## 1. Create the tunnel (dashboard, once)

1. Cloudflare dashboard -> Zero Trust -> Networks -> Tunnels -> **Create tunnel** -> type **Cloudflared** -> name it (e.g. `ai-workstation-cli`).
2. On the **Install and run a connector** screen, select the VPS platform:
   - OS: **Debian** (the VPS is Ubuntu/Debian-based; use Red Hat only on RHEL-family hosts).
   - Architecture: **64-bit** on an amd64 VPS (`uname -m` shows `x86_64`), **arm64-bit** on an ARM VPS.
3. The screen shows an install command containing a **connector token** (the long `eyJh...` string). Copy the token. (If you lose it, add another connector in the same screen — it issues a fresh token; old connectors keep working.)
4. In Cloudflare Zero Trust -> Access, add an application policy for every hostname below (for example, email OTP or Google login). Do not skip this: the dev server and DSH have no login of their own.

## 2. Install the connector (on the VPS, once)

```bash
ai tunnel setup
ai tunnel status
```

`ai tunnel setup` asks for the connector token (input hidden, stored `600` at `secrets/cloudflared-token`), both hostnames, and the app local port (defaults to the detected app port). It installs `cloudflared` if missing (amd64/arm64), installs the connector service, and stores the hostnames in `.env`.

## 3. Add the public hostnames (dashboard, once per hostname)

In the tunnel -> **Public hostnames** -> Add (origin = VPS itself). Only two fields matter; leave everything else at defaults:

| Field | App (Dev Server) | DSH (AI Engine) | Web API Daemon (Optional) |
|---|---|---|---|
| Hostname | `app` | `dsh` | `api` |
| Domain | your domain | your domain | your domain |
| Path | empty | empty | empty |
| Service Type | `HTTP` | `HTTP` | `HTTP` |
| URL | `127.0.0.1:<app-port>` (from `ai preview`) | `127.0.0.1:4090` | `127.0.0.1:8000` |

Leave at defaults: HTTP Host Header empty, Chunked Encoding Off, timeouts as shown, Enforce Access JWT validation **Off** (the edge Access policy already gates traffic), Applications unselected.

Result:

```text
App    : https://app.example.com
DSH    : https://dsh.example.com
API    : https://api.example.com
```

## More apps

The workstation runs one active project at a time, so only the active app answers. Recommended: one hostname per project, each pointing at that project's dev port (no dashboard edits when switching):

```text
portfolio.example.com -> http://127.0.0.1:5173
paradinha.example.com -> http://127.0.0.1:3000
dsh.example.com       -> http://127.0.0.1:4090
```

Inactive projects return 502 until you `ai use` them — expected, not an error. Every project port must be host-bound in `docker/compose.yml` (covered: `3000, 3001, 5173, 8080, 8000`). Each hostname needs its own Access policy (or one `*.example.com` policy) and its own dev-server hostname allowlist (below).

Daily switching stays:

```bash
ai use <project>
ai run
ai preview
```

## DSH settings are loopback-only

DSH's Settings pages (Models, Plugins, Agent presets) load **only** on a loopback page (`127.x`, `localhost`, `[::1]`). On any other address — tunnel hostname, LAN IP, reverse proxy — the browser client itself refuses (`Loading the provider directory failed: settings are unavailable in this browser`). This is upstream design, not a misconfiguration: no `--trusted-host`, tunnel setting, header rewrite, or upgrade changes it. The server fence (`--trusted-host`, wired automatically by `ai tunnel setup`) covers the API; this separate client gate covers the settings UI.

What works from anywhere: chat, sessions, workspaces, provider *use*. What needs loopback once: entering/changing API keys and credentials.

Workarounds (one time):

1. **Via SSH (recommended):** on your machine run `ssh -N -L 4090:<container-ip>:4091 <vps>` (container IP from `ai preview`), open `http://127.0.0.1:4090` (+ token from `ai preview`'s `DSH open:` line) → Settings → Models → Apply. Keys persist server-side.
2. **File edit:** keys live in `~/ai-workstation-cli/runtime/dsh/settings.yaml` on the VPS (hot-reloaded, no restart). Configure once via method 1, then `cat` that file as the schema template for future edits.

Do not chase this error with tunnel, Access, WAF, or header changes — verified end to end: same browser gets `200 OK` on the API through the tunnel while the settings pane still refuses. That combination *is* the signature of this gate.

## Keep the app port in sync

No extra command needed. `ai preview` auto-detects the listening app port and prints the Anywhere URLs every time. If the port changed, it also prints the one dashboard click required (tunnel -> Public hostnames -> edit the app hostname to the new port). Ingress lives in the dashboard, so the port edit happens there — nothing restarts, nothing reloads.

```bash
ai preview
ai tunnel status
```

`ai preview` also prints a ready-to-open DSH line when DSH has issued a login token:

```text
Anywhere URLs:
  App : https://app.example.com
  DSH : https://dsh.example.com
  DSH open: https://dsh.example.com/?token=...
```

Bookmark the `DSH open:` URL — it works from anywhere with no VPS access until the next harness restart (which rotates the token).

## Manage

```bash
ai tunnel status
ai tunnel start
ai tunnel stop
ai tunnel logs
```

## Framework hostname checks

Tunnels change the `Host` header. `ai tunnel setup` stores the app hostname in `ALLOWED_HOSTS`, which the workstation passes into the container — no hardcoded domains in project files:

- Vite: read it in `vite.config.js`:
  ```js
  allowedHosts: [
    'localhost',
    '127.0.0.1',
    ...(process.env.ALLOWED_HOSTS ?? '').split(',').map((h) => h.trim()).filter(Boolean),
  ],
  ```
- Next.js: `experimental.allowedDevOrigins` from the same variable (or list hostnames explicitly).
- Other servers: equivalent allowed-hosts / trusted-hosts setting fed by `$ALLOWED_HOSTS`.
- Multiple projects: comma-separated list, e.g. `ALLOWED_HOSTS=app.example.com,paradinha.example.com`.

## Troubleshooting

```bash
ai tunnel status
sudo journalctl -u cloudflared -n 50
ai preview
```

- Cloudflare error 1033/502: connector down or wrong origin port (compare `ai preview` port with the dashboard route).
- DSH page loads but `/api/*` returns bare `forbidden`: the DSH browser-trust fence doesn't know the public hostname. `ai tunnel setup` stores it in `DSH_TRUSTED_HOSTS` automatically; if the hostname was added later, set it and recreate the workstation (a plain `ai restart` does not pick up env changes):
  ```bash
  grep '^DSH_TRUSTED_HOSTS=' ~/ai-workstation-cli/.env || echo "DSH_TRUSTED_HOSTS=<dsh-host>" >> ~/ai-workstation-cli/.env
  ai stop && ai start
  ```
- App 403 Invalid Host: allowlist the hostname (above).
- Stuck at Cloudflare login loop: Access policy misconfigured.
- Connector token revoked: re-run `ai tunnel setup` with the fresh token.

## When not to use it

Prefer plain SSH tunneling for daily work on trusted machines. Use the Cloudflare path only when you genuinely need access without your own SSH client (another device, another network).
