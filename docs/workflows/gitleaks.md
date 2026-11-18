# gitleaks (reusable)

Source: `.github/workflows/gitleaks.yml`

| | |
|---|---|
| **Trigger** | `workflow_call` with `mode` `pr` or `full`. |
| **Runner** | GitHub-hosted (`ubuntu-latest`), no credentials |
| **Touches** | Scans the checkout for secrets. Reads rules from `.github/gitleaks.toml` on petedio-iac `main`. |
| **Vault** | None. |
| **Secrets** | None. |
| **Gates** | <br>• Downloads one pinned gitleaks release and checks its SHA-256 before it runs. No third-party action.<br>• Fails closed: zero commits read is red.<br>• `--redact` keeps secrets out of the log; the summary states the commit count. |
| **Run it** | Call from `gitleaks-caller.yml`. |


