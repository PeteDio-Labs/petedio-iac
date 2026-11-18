# portfolio-plan

Source: `.github/workflows/portfolio-plan.yml`

| | |
|---|---|
| **Trigger** | `workflow_dispatch`. |
| **Runner** | Self-hosted runner on the LAN (LXC 232 or 233, label `[self-hosted, linux, x64, homelab]`) |
| **Touches** | `terraform plan` for `environments/portfolio` (S3, CloudFront, ACM, a deploy IAM user). Plan only. |
| **Vault** | Role `portfolio-plan`, reads `kv/services/aws-portfolio-plan` (MinIO and read-only AWS key pairs). |
| **Secrets** | None in Actions. |
| **Gates** | <br>• The AWS key belongs to a read-only IAM user, so the workflow cannot change AWS.<br>• `main` only; the role binds ref, event and this file.<br>• The log prints counts and addresses with `[instance key]` removed, never attribute values. |
| **Run it** | `gh workflow run portfolio-plan.yml --ref main`. To apply, use `aws-apply`. |

`aws-apply` supersedes this workflow for applies. It stays as a plan-only path with a single read-only key.
