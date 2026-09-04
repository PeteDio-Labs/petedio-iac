# ⛔ Do not merge to `main` until the node drift is fixed

**Status: open, 2026-09-04.** Read this before merging anything in this repo.

## What changed

`runner-233` was rebuilt on pve02 and is online again, so **apply-on-merge can
execute for the first time since pve01 died**. While both runners were offline a
merge simply queued a job that never ran. That is no longer true: the next push
to `main` runs `terraform apply` against live infrastructure.

## Why that is dangerous right now

`variable "target_node"` still defaults to **`pve01`**, and **10 resources use
it**:

```
authentik.tf  minio-data.tf  faas.tf     plane.tf   poker.tf
postgres.tf   registry.tf    tailscale.tf  vault.tf   runner.tf
```

pve01 is not merely powered off — it was removed from the cluster with
`pvecm delnode pve01`, and `/etc/pve/nodes/pve01` is gone. Terraform is being
asked to reconcile ten containers onto a node that does not exist.

A second, narrower drift: `module.runner_2` declares
`datastore_id = "pve02-shared"`, but the rebuilt container lives on
**`local-lvm`**, because `pve02-shared` is where its original disk was lost.
Terraform will read that as a change requiring **destroy and recreate** — which
destroys the runner that is executing the apply.

## What has NOT been established

Nobody has run a plan against this state. The failure mode above is inferred
from the code and the live cluster, not observed. It could equally fail early
and harmlessly on a provider error.

**That uncertainty is the reason for the block.** The repo's own rule is to read
the actual plan and never apply by hand; neither has happened here.

## How to clear this

1. Produce a plan from an operator machine with the LAN, Vault and MinIO
   credentials — `terraform plan` in `environments/homelab/`, and **read it**.
2. Expect to change at least:
   - `variable "target_node"` default, `pve01` → `pve02`
   - `module.runner_2`'s `datastore_id`, `pve02-shared` → `local-lvm`
   - `module.runner` (232) — decide whether the dead runner is removed from
     config and state, or re-pointed at a live node
3. Confirm the plan shows **no destroy** of a running guest. An empty plan is
   also a failure — it means the backend is not being read.
4. Then merge, and delete this file in the same change.

## Interim state

`runner-233` is left **online** on purpose. It serves CI for `co-latro-backend`,
`co-latro-frontend`, `water-fast`, `resume-builder` and `petedio-media-iac`,
none of which apply this configuration. The hazard is specific to merging
**this** repo.

To remove the hazard entirely rather than relying on nobody merging:

```bash
ssh pve02 'pct exec 233 -- systemctl stop actions.runner.PeteDio-Labs.runner-233.service'
```

That returns the repo to the state it was in all day — merges queue, nothing
applies — and costs the other five repos their CI until it is started again.
