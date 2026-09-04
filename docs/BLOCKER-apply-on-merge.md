# ⛔ Do not merge to `main` until the state is corrected

**Status: partly fixed, 2026-09-04.** Read this before merging anything here.

## What is fixed

A plan was run from an operator machine against the live MinIO backend, using
credentials read from Vault. It found three config faults, all now corrected:

| Was | Now | Why it mattered |
|---|---|---|
| `proxmox_endpoint` = `https://192.168.50.10:8006/` | `.11` (pve02) | `.10` was pve01's address and **now belongs to pve03** — the provider was aimed at a different machine than the one holding the guests |
| `target_node` default = `pve01` | `pve02` | ten resources take this default |
| `modules/proxmox-lxc` node default = `pve01` | `pve02` | a module default naming an unresolvable node fails at refresh, not at plan |
| `runner_2` `datastore_id` = `pve02-shared` | `local-lvm` | matches where the rebuilt container actually lives |

The plan confirmed the runner change is an **in-place update, not a
destroy-and-recreate** — the earlier worry about it destroying the runner mid-apply
was wrong.

## What is NOT fixed, and still blocks a merge

**The state records 10 resources on `node_name = pve01`.** Config alone cannot fix
this; terraform refreshes each resource against the node named in state, and gets:

```
Error: received an HTTP 500 response - Reason: hostname lookup 'pve01' failed
```

Those ten split into two groups, and they need different treatment:

**Five exist on pve02 right now** — the restore put them there, and only the state
disagrees:

| VMID | Guest |
|---|---|
| 119 | authentik |
| 223 | vault |
| 231 | postgres-rds |
| 235 | plane |
| 245 | minio-data |

For these, rewriting `node_name` to `pve02` is a correction of fact.

**Five exist nowhere** — they died with pve01 and were never restored:

| VMID | Guest | Note |
|---|---|---|
| 106 | registry (Zot) | `docker.pdlab.dev`; needs its blob store back |
| 230 | poker-api | |
| 232 | runner | superseded by the rebuilt runner-233 |
| 241 | openfaas | hosts `lab-graph` |
| 244 | tailscale | superseded by the subnet router on pete-pi-1 |

For these, pointing state at pve02 makes terraform find them missing and plan to
**create all five**. That may well be what you want — it is most of the rest of
the restore — but it must be a decision, not a surprise on the next merge.

## Why the state was not corrected

Rewriting and pushing terraform state is a high-impact action and was refused by
the permission classifier, correctly. It needs an explicit go-ahead.

The intended change is mechanical: `terraform state pull`, rewrite
`node_name` from `pve01` to `pve02`, bump `serial`, `terraform state push`.
MinIO versioning on the `tfstate` bucket is the recovery net, and a local copy of
the pre-change state is kept alongside.

## How to clear this

1. Decide what happens to the five absent guests — restore them, or remove them
   from config and state.
2. Correct `node_name` in state for the five that exist.
3. Re-run the plan and **read it**. It must show no destroy of a running guest.
   Note the pool resource shows a destroy when `manage_resource_pool=false`; the
   repo variable `MANAGE_RESOURCE_POOL` is `true`, so plan with it set to match
   CI or that destroy is an artifact of your local run.
4. Merge, and delete this file in the same change.

## Interim state

`runner-233` stays **online** — it serves CI for `co-latro-backend`,
`co-latro-frontend`, `water-fast`, `resume-builder` and `petedio-media-iac`, none
of which apply this configuration.

The refresh error is currently load-bearing: an apply **fails** rather than doing
damage. Do not "fix" it by pointing state at a live node without first deciding
about the five absent guests.

To remove the hazard entirely rather than relying on nobody merging:

```bash
ssh pve02 'pct exec 233 -- systemctl stop actions.runner.PeteDio-Labs.runner-233.service'
```
