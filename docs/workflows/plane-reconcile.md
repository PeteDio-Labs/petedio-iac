# plane-reconcile (reusable)

Source: `.github/workflows/plane-reconcile.yml`

| | |
|---|---|
| **Trigger** | `workflow_call`, `workflow_dispatch`. |
| **Runner** | Self-hosted runner on the LAN (LXC 232 or 233, label `[self-hosted, linux, x64, homelab]`) |
| **Touches** | Re-reads recently merged PRs of the calling repo and fixes any work item a missed webhook left behind. |
| **Vault** | Role `plane-ci`, `kv/services/plane` `api_key`. |
| **Secrets** | `github.token` of the caller (no org-wide token). |
| **Gates** | `github.repository` and `github.token` come from the caller, so each repo needs its own caller (PET-363). Inert until `PLANE_BASE_URL`, `PLANE_WORKSPACE` and `PLANE_PROJECT_ID` are set. |
| **Run it** | Called by `plane-reconcile-caller.yml`. |


