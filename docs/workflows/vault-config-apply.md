# vault-config-apply

Source: `.github/workflows/vault-config-apply.yml`

| | |
|---|---|
| **Trigger** | `workflow_dispatch` with input `pet`. |
| **Runner** | Self-hosted runner on the LAN (LXC 232 or 233, label `[self-hosted, linux, x64, homelab]`) |
| **Touches** | Plan and apply of `environments/homelab/vault-config` (Vault policies, auth roles) with its own state in MinIO. |
| **Vault** | Plan: role `vault-config-plan`. Apply: role `vault-config-apply`. Both read `kv/iac/minio`. |
| **Secrets** | None in Actions. |
| **Gates** | <br>• `plan` needs no approval; it prints what the guard examined and a digest.<br>• `apply` waits on `lab-write` and re-plans. It applies only when the guard passes and the digest equals the plan job's.<br>• A plan with no changes skips the apply job.<br>• Anything the guard refuses stays a Mac step (`scripts/apply-vault-config.sh`). Limits: `vault-config/vault-config-apply.tf`.<br>• `main` only. |
| **Run it** | `gh workflow run vault-config-apply.yml --ref main -f pet=PET-<n>`. Pedro approves the apply job. |


