# terraform-plan (PR plan comment)

Source: `.github/workflows/terraform-plan-pr.yml`

| | |
|---|---|
| **Trigger** | `workflow_run` after `terraform` (main's copy runs, whoever opened the PR). |
| **Runner** | `inspect`: GitHub-hosted (`ubuntu-latest`), no credentials, no `id-token`. `plan`: self-hosted LAN runner. |
| **Touches** | Plans `environments/homelab` for a same-repo PR and comments counts and addresses. Writes no state; has no apply step. |
| **Vault** | Role `deploy-terraform-plan`, bound to this file on `main` and event `workflow_run`. Reads `kv/iac/minio`, `kv/iac/proxmox`, `kv/iac/cloudflare`. |
| **Secrets** | None in Actions. |
| **Gates** | <br>• Same-repo PRs only; a fork is never planned.<br>• `inspect` runs `tf-plan-guard.py` (text) and `tf-plan-inspect.py` (parsed HCL against main). A refused PR gets a comment that says to plan locally.<br>• `plan` checks out the exact merge commit `inspect` examined.<br>• Providers install only from a mirror of main's lock file.<br>• `-lock=false`; plan files are mode 0600 and deleted.<br>• The comment redacts `[instance key]` and shows no attribute values. |
| **Run it** | Open or update a same-repo PR. Scope is `environments/homelab` only. |

The guards are an allowlist of what a PR may change, not proof it is safe. `docs/GOTCHAS.md` records the `python-hcl2` gap.
