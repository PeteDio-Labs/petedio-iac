# plane-reconcile-caller

Source: `.github/workflows/plane-reconcile-caller.yml`

| | |
|---|---|
| **Trigger** | Daily `schedule` 08:17 UTC, `workflow_dispatch`. |
| **Runner** | Self-hosted, via `plane-reconcile.yml@main`. |
| **Touches** | Calls the reusable workflow for petedio-iac. |
| **Vault** | Via `plane-ci`. |
| **Secrets** | None. |
| **Gates** | Cron minutes are staggered by five per repo so queued nightly runs do not miss their window. |
| **Run it** | `gh workflow run plane-reconcile.yml`. |


