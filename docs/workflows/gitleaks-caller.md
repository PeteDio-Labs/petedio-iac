# gitleaks-caller

Source: `.github/workflows/gitleaks-caller.yml`

| | |
|---|---|
| **Trigger** | `pull_request`, weekly `schedule` (Monday 09:17 UTC), `workflow_dispatch`. |
| **Runner** | Hosted, via `gitleaks.yml`. |
| **Touches** | Calls `gitleaks.yml` in `pr` mode on a PR, `full` mode otherwise. |
| **Vault** | None. |
| **Secrets** | None. |
| **Gates** | Read-only `contents`. Other repos call `PeteDio-Labs/petedio-iac/.github/workflows/gitleaks.yml@main`. |
| **Run it** | `gh workflow run gitleaks-caller.yml`. |


