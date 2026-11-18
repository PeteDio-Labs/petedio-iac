# secrets-register

Source: `.github/workflows/secrets-register.yml`

| | |
|---|---|
| **Trigger** | `pull_request`, daily `schedule` 06:17 UTC, `workflow_dispatch`. |
| **Runner** | `offline`: hosted, no credentials. `nightly`: Self-hosted runner on the LAN (LXC 232 or 233, label `[self-hosted, linux, x64, homelab]`) |
| **Touches** | Checks `secrets/register.yml` against code (PR) and against Vault KV metadata (nightly). On failure DMs Pedro through pete-bot. |
| **Vault** | Role `secrets-register`, metadata read only. Optional `kv/services/secrets-register` `notify_bearer_token`. |
| **Secrets** | None in Actions. |
| **Gates** | <br>• A PR fails if it reads a Vault path no register entry owns.<br>• Nightly fails when a path is absent or an expiry is within 21 days.<br>• Exits non-zero below a floor, so reading nothing is red. |
| **Run it** | `scripts/seed-secrets-register.sh` seeds the notify token. See `docs/runbooks/secrets-register.md`. |


