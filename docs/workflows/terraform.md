# terraform

Source: `.github/workflows/terraform.yml`

| | |
|---|---|
| **Trigger** | `pull_request` and `push` to `main`. No `workflow_dispatch`. |
| **Runner** | `validate`: GitHub-hosted (`ubuntu-latest`). `plan-gate` and `apply`: self-hosted LAN runner. `approve-destroy`: hosted, no credentials. |
| **Touches** | `environments/homelab`: Proxmox (API token), Cloudflare, MinIO state. |
| **Vault** | Role `github-actions` (push on `main` only). Reads `kv/iac/minio`, `kv/iac/proxmox`, `kv/iac/lxc-ssh` (public key), `kv/iac/cloudflare`. |
| **Secrets** | None in Actions. |
| **Gates** | <br>• `validate` (fmt, `init -backend=false`, `validate`, script tests) has no Vault, no LAN and no state, so PR-controlled code never reaches a credential.<br>• `plan-gate` plans every merge and inspects it for removals.<br>• A plan that destroys or replaces anything sets `needs_approval`, and job `approve-destroy` waits on `lab-write` before `apply` runs. Repo variable `ALLOW_DESTROY=true` skips the wait; it stays off.<br>• `apply` runs only on a push to `main`, after `validate` and `plan-gate`, and applies the saved plan.<br>• Applies share one concurrency group and never cancel (S3-native lockfile; bucket versioning is the recovery net). Validation is scoped per ref so a PR cannot cancel an apply. |
| **Run it** | Open a PR for `validate`. A merge runs the plan and apply. Never apply by hand. Read the apply log as the authoritative plan. |

Do not add a trigger or drop an `if:` guard: a non-push event reaching an apply would let a pull request cancel a mid-flight apply. See `docs/GOTCHAS.md`.
