## Summary

<!-- Provide a concise description of what this pull request does. -->

## Motivation

<!-- Explain why this change is necessary. Reference any related issues (e.g., Closes #123). -->

## Changes

<!-- Detail the changes made, grouped by component or file. -->
- 

## Testing and Validation

<!-- Describe how you verified these changes. Include exact commands and outcomes. -->
- [ ] Static syntax checks passed (`bash -n`, `python3 -m py_compile`)
- [ ] Docker Compose config validated (`docker compose -f docker/compose.yml config`)
- [ ] Integration validation completed on test environment:
  - Details: 

## Security Considerations

<!-- Address any impact on container isolation, permissions, mounts, credentials, or state handling. -->
- **Container Isolation Impact**: None / Described below
- **Mounts / Secrets**: No secrets exposed or mounted
- **Details**: 

## Documentation

<!-- Describe any updates made to README.md, comments, or help text. -->
- [ ] README.md updated (if applicable)
- [ ] CLI help text / usage updated (if applicable)
- [ ] No documentation changes required

## Compatibility and Breaking Changes

<!-- Are there breaking changes to CLI syntax, environment variables, mounts, or supported platforms? -->
- [ ] No breaking changes
- [ ] Breaking changes documented with upgrade/migration instructions below:

## Contributor Checklist

Please verify each item before submitting:

- [ ] My pull request is focused on a single logical change.
- [ ] I have run `git diff --check` and verified no whitespace or formatting errors exist.
- [ ] I have verified that all modified scripts pass syntax checks (`bash -n <script>`).
- [ ] I have run `aiws doctor` (where applicable on a live workstation host).
- [ ] **No secrets, tokens, private keys (`*.pem`), credentials, or `.env` files are committed**.
- [ ] **No host runtime state (`runtime/`, `secrets/`, `*.tar.gz`) is committed**.
- [ ] The existing security model (non-root `sandbox`, no Docker socket, no host `~/.ssh`) is preserved.
- [ ] Relevant documentation has been updated.

