# Workflows

One page per workflow in `.github/workflows/`. Each page lists the trigger, the runner, what the workflow touches, its Vault access, its gates and how to run it. Secrets appear by path or name only.

## Trust model

- The repository is public and the LAN runners (LXC 232 and 233) sit inside the lab, so a `pull_request` never runs on them (PET-104, PET-407).
- Credentials come from Vault by GitHub OIDC. Roles bind repository, ref, event and workflow file.
- `lab-write` is a GitHub environment with Pedro as its only reviewer. Every write that moves lab or AWS state waits on it.
- The AWS account SCP blocks IAM OIDC providers (PET-816). `aws-apply` uses scoped IAM-user keys stored in Vault, released only to the approved job.

## PR checks

- [`ansible-validate`](ansible-validate.md)
- [`blast-radius`](blast-radius.md)
- [`import-gated-guard`](import-gated-guard.md)
- [`keys-check`](keys-check.md)
- [`gitleaks-caller`](gitleaks-caller.md)
- [`gitleaks`](gitleaks.md)

## Plan and apply

- [`terraform`](terraform.md)
- [`terraform-plan-pr`](terraform-plan-pr.md)
- [`vault-config-apply`](vault-config-apply.md)
- [`aws-apply`](aws-apply.md)
- [`portfolio-plan`](portfolio-plan.md)

## Lab actions

- [`lab-action`](lab-action.md)
- [`cf-access-logs`](cf-access-logs.md)
- [`keys`](keys.md)
- [`branch-cleanup`](branch-cleanup.md)
- [`staging-power`](staging-power.md)

## Host deploys

- [`ansible-claude-247`](ansible-claude-247.md)
- [`deploy-backup-store`](deploy-backup-store.md)
- [`deploy-codex-248`](deploy-codex-248.md)
- [`deploy-lab-watchdog`](deploy-lab-watchdog.md)
- [`deploy-metrics`](deploy-metrics.md)
- [`deploy-minio-data`](deploy-minio-data.md)
- [`deploy-plane`](deploy-plane.md)
- [`deploy-staging-249`](deploy-staging-249.md)
- [`deploy-uptime-kuma`](deploy-uptime-kuma.md)

## Tracker and registers

- [`plane-sync`](plane-sync.md)
- [`plane-sync-caller`](plane-sync-caller.md)
- [`plane-reconcile`](plane-reconcile.md)
- [`plane-reconcile-caller`](plane-reconcile-caller.md)
- [`secrets-register`](secrets-register.md)

