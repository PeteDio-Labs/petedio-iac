# staging-power

Source: `.github/workflows/staging-power.yml`

| | |
|---|---|
| **Trigger** | `schedule` every 5 minutes, `workflow_dispatch` with `mode` (`start`, `stop`, `status`, `auto`). |
| **Runner** | Self-hosted runner on the LAN (LXC 232 or 233, label `[self-hosted, linux, x64, homelab]`) |
| **Touches** | Starts or stops CT 249 (portfolio staging) on pve03 through a certificate fixed to one script. |
| **Vault** | Roles `staging-power-<event>` (`vault-config/staging-power.tf`). |
| **Secrets** | None. |
| **Gates** | <br>• `auto` starts CT 249 while `staging` has recent UI work and stops it after promotion to `main` or 3 hours without a push.<br>• `main` only; schedule or dispatch only; no `pull_request`.<br>• The dispatch input is never passed to a shell; `scripts/staging-power.py` reads it from a closed list.<br>• A run that cannot read GitHub or the node fails and stops nothing. |
| **Run it** | `gh workflow run staging-power.yml --ref main -f mode=start`. |


