# aws-apply

Source: `.github/workflows/aws-apply.yml`

| | |
|---|---|
| **Trigger** | `workflow_dispatch` with inputs `root` (`dashboard` or `portfolio`), `attach_domain`, `apply`, `pet`. |
| **Runner** | Self-hosted runner on the LAN (LXC 232 or 233, label `[self-hosted, linux, x64, homelab]`) |
| **Touches** | Terraform for `environments/<root>` in AWS account 847547470418, with state in MinIO. The `apply` job runs only when the `apply` input is true. |
| **Vault** | Plan job: role `deploy-aws-plan`, reads `kv/services/aws-ci/<root>-plan` (MinIO key pair, read-only AWS key pair). Apply job: role `deploy-aws-apply`, reads `kv/services/aws-ci/<root>-apply`. |
| **Secrets** | None in Actions. Keys exist only in Vault, by path. |
| **Gates** | <br>• The account's SCP blocks IAM OIDC providers (PET-816), so a job cannot assume an AWS role. Scoped IAM-user keys sit in Vault instead.<br>• The plan key (`petedio-ci-<root>-plan`) has `ReadOnlyAccess`. The apply key (`petedio-ci-<root>-apply`) writes only that root's named resources.<br>• The apply job is bound to `lab-write`, and Vault refuses the apply role until Pedro approves, so the apply key is released by the tap.<br>• The apply job re-plans and applies the saved plan only when its digest equals the plan job's digest (address, instance key and values).<br>• `main` only. Vault roles bind ref, event and this file.<br>• Tokens last 15 minutes. |
| **Run it** | `gh workflow run aws-apply.yml --ref main -f root=portfolio` plans. Add `-f apply=true` to request an apply, then Pedro approves. `scripts/seed-aws-ci.sh` creates the IAM users and places keys; Pedro runs it once. |

Limit: a leaked Vault token holding the apply role could read an apply key. The key's policy names each root's resources, so it cannot touch the rest of the account.
