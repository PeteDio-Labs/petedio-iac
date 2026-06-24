# Proxmox resource pool grouping all petedio-iac-managed LXCs (PET-56). Org hygiene only —
# a pool is a metadata grouping in the Proxmox UI/API; it changes NOTHING about the
# containers themselves.
#
# NON-DESTRUCTIVE BY DESIGN: membership uses proxmox_pool_membership (the by-id form), which
# adds each LXC to the pool WITHOUT touching the container resource. So the
# first plan is ADD-ONLY (1 pool + N memberships; 0 change / 0 destroy) and no live LXC is
# ever recreated. (Setting `pool_id` on each container instead would churn the shared module
# and every consumer — avoided.)
#
# Provider note: pool_membership needs bpg/proxmox >= ~0.66; the workspace is already at
# 0.109.0 (.terraform.lock.hcl), so NO provider bump was required — the PET-56 "may need a
# bump" flag was stale.
#
# Permission note (operator, out-of-band — see the PR): creating/modifying a pool needs
# `Pool.Allocate` on the IaC API token. Its roles (PVEVMAdmin / PVEDatastoreUser, per
# docs/GOTCHAS.md) do NOT include it, so the first apply 403s until it's granted — the same
# shape as the SDN.Use / features gotchas. Grant once on the node.
#
# POISON-PILL GUARD (PET-159/PET-160): that 403 is on the pool CREATE, which runs before
# everything else here, so a missing `Pool.Allocate` failed apply-on-merge for the WHOLE
# workspace — low-priority org hygiene blocked every unrelated apply. So the pool is now gated
# behind `var.manage_resource_pool` (default false): off, this whole file is a no-op (count 0
# / empty for_each — nothing created or destroyed), so applies are never blocked by the pool
# perm. Flip the repo var MANAGE_RESOURCE_POOL=true AFTER granting Pool.Allocate (the PET-159
# runbook); CI's preflight (scripts/proxmox-preflight-perms.sh) then verifies the priv at PR
# time before the change can merge. NB: PET-159's apply 403'd on the CREATE, so the pool never
# entered state — turning the gate on later is a create (not a destroy); confirm via plan.

resource "proxmox_virtual_environment_pool" "homelab" {
  count = var.manage_resource_pool ? 1 : 0

  pool_id = "homelab"
  comment = "All petedio-iac-managed LXCs. Managed by Terraform (PET-56)."
}

locals {
  # vm_id sourced from each module's output → an implicit dependency, so a membership is
  # created after its container exists. Imported/captured LXCs (e.g. nexus) are included too:
  # membership is additive and never mutates the container. authentik-119 / runner-233 will
  # be added here when their PRs merge. Gated by the same flag as the pool itself.
  pool_lxc_members = var.manage_resource_pool ? {
    nexus      = module.nexus.vm_id
    vault      = module.vault.vm_id
    poker_api  = module.poker_api.vm_id
    postgres   = module.postgres_host.vm_id
    runner     = module.runner.vm_id
    openfaas   = module.openfaas.vm_id
    agent_loop = module.agent_loop.vm_id
  } : {}
}

# proxmox_pool_membership (NOT the deprecated _virtual_environment_ alias). `type` is
# read-only — the provider infers lxc vs qemu from the vm_id — so only pool_id + vm_id are set.
resource "proxmox_pool_membership" "lxc" {
  for_each = local.pool_lxc_members

  pool_id = proxmox_virtual_environment_pool.homelab[0].pool_id
  vm_id   = each.value
}
