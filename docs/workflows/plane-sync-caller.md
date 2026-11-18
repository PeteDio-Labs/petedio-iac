# plane-sync-caller

Source: `.github/workflows/plane-sync-caller.yml`

| | |
|---|---|
| **Trigger** | `pull_request_target`, `workflow_dispatch`. |
| **Runner** | Self-hosted, via `plane-sync.yml@main`. |
| **Touches** | Calls the reusable workflow. |
| **Vault** | Via `plane-ci`. |
| **Secrets** | None. |
| **Gates** | See `plane-sync`. |
| **Run it** | Copy to each repo. |


