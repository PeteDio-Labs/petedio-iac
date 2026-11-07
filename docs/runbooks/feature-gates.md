# Feature gates

The four homelab gates live in `environments/homelab/flags.auto.tfvars` (PET-884):
`manage_resource_pool`, `manage_backup_job`, `email_routing_live` and `email_routing_forward`.
Terraform loads the file by itself, so CI and a local plan read the same values.

## Change a gate

1. Meet the gate's prerequisite. The variable's description names it.
2. Edit the value in `flags.auto.tfvars` and open a pull request.
3. Read the apply-on-merge plan. A gate pull request gets no plan comment, because
   `scripts/tf-plan-guard.py` refuses `.auto.tfvars` paths on a pull request. To see the plan
   before the merge, run `terraform plan` locally.

A gate that reads `false` makes its resources a no-op. If the file goes missing, every gate
falls back to `false` and the plan removes the pool, the backup job and both email-routing
resources. `scripts/test-flags-tfvars.sh` runs in `validate` and fails when the file is absent.

## Approve a deliberate destroy

A merge whose plan removes resources waits in the `approve-destroy` job on the `lab-write`
environment. Tap Approve in the GitHub app after you read the plan-gate summary. Do not set
`ALLOW_DESTROY`: it skips the wait.
