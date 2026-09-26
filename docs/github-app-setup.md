# GitHub App Setup

GitHub access is brokered through a GitHub App. No PAT or SSH private key is copied into the workstation container.

You need three values:

```text
GitHub App ID
GitHub Installation ID
GitHub App private key (.pem)
```

## 1. Create a GitHub App

1. On GitHub.com, go to Settings -> Developer settings -> GitHub Apps -> New GitHub App.
2. Fill in a name and Homepage URL (for example, `https://example.com`).
3. Disable Webhook if you do not need it.
4. Set minimum permissions, for example:
   - Contents: Read and write
   - Metadata: Read-only
   - Pull requests: Read and write
5. Create the App.
6. Note the `App ID` shown on the App general page.

## 2. Generate the private key

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

## 3. Install the App and get the Installation ID

1. On the App page, select `Install App`.
2. Install it on your account or selected repositories.
3. After installation, copy the `Installation ID` from the installation URL:
   ```text
   https://github.com/settings/installations/<INSTALLATION_ID>
   ```

## 4. Copy the private key from your local machine to the VPS

`ai github setup` runs on the VPS and expects a VPS-local `.pem` path. Copy the downloaded file from your local machine first.

From your local machine:

```bash
ssh <user>@<vps-host> "mkdir -p ~/ai-workstation-cli/secrets && chmod 700 ~/ai-workstation-cli/secrets"

scp /path/to/<app-name>.<date>.private-key.pem \
  <user>@<vps-host>:~/ai-workstation-cli/secrets/github-app.pem
```

Example:

```bash
scp "/Users/mosabbirmaruf/Downloads/ai-dev-workstation.2026-09-23.private-key.pem" \
  mosabbir-cloud:~/ai-workstation-cli/secrets/github-app.pem
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
>   mosabbir-cloud:~/ai-workstation-cli/secrets/github-app.pem
> ```
>
> If you pasted to `~/.ssh/`, adjust the path accordingly. Do not use `cp` in Terminal to move it — the same block will hit. Use Finder drag/copy.

Then, on the VPS:

```bash
chmod 600 ~/ai-workstation-cli/secrets/github-app.pem
ls -l ~/ai-workstation-cli/secrets/github-app.pem
head -1 ~/ai-workstation-cli/secrets/github-app.pem
```

The final private key belongs at:

```text
~/ai-workstation-cli/secrets/github-app.pem
```

## 5. Configure and test

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
~/ai-workstation-cli/secrets/github-app.pem
```

or, if you used the temporary-path method:

```text
/tmp/github-app.pem
```

(`~/...` works; setups before the tilde-expansion fix need the full path, e.g. `/home/mosabbir/ai-workstation-cli/secrets/github-app.pem`.)

Setup copies the key to `~/ai-workstation-cli/secrets/github-app.pem`, saves the App and Installation IDs to `.env`, and starts the broker service.

A successful authentication test should report:

```text
Testing GitHub App credentials...
✓ GitHub Installation Token: OK

GitHub authentication: READY ✓
```

## Troubleshooting

If `ai github test` fails with `Algorithm 'RS256' could not be found`, the Python `cryptography` backend is missing:

```bash
~/ai-workstation-cli/.venv/bin/pip install "PyJWT[crypto]"
~/ai-workstation-cli/.venv/bin/python -c 'from jwt.api_jws import PyJWS; PyJWS().get_algorithm_by_name("RS256"); print("RS256 OK")'
sudo systemctl restart ai-github-broker
ai github test
```

New installs get this automatically via `./install.sh`.
