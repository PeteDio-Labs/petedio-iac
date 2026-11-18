# keys-check

Source: `.github/workflows/keys-check.yml`

| | |
|---|---|
| **Trigger** | `pull_request`. |
| **Runner** | GitHub-hosted (`ubuntu-latest`), `permissions: {}` |
| **Touches** | Validates `secrets/callers.yml` and route `agents` lists; drives `scripts/keys.py` against a fake Vault and fake Cloudflare. |
| **Vault** | None. |
| **Secrets** | None. |
| **Gates** | Each step's last line says what it read; reading nothing is red. |
| **Run it** | Open a PR. |


