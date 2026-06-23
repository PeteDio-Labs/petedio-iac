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

resource "proxmox_virtual_environment_pool" "homelab" {
  pool_id = "homelab"
  comment = "All petedio-iac-managed LXCs. Managed by Terraform (PET-56)."
}

locals {
  # vm_id sourced from each module's output → an implicit dependency, so a membership is
  # created after its container exists. Imported/captured LXCs (e.g. nexus) are included too:
  # membership is additive and never mutates the container. authentik-119 / runner-233 will
  # be added here when their PRs merge.
  pool_lxc_members = {
    nexus      = module.nexus.vm_id
    vault      = module.vault.vm_id
    poker_api  = module.poker_api.vm_id
    postgres   = module.postgres_host.vm_id
    runner     = module.runner.vm_id
    openfaas   = module.openfaas.vm_id
    agent_loop = module.agent_loop.vm_id
  }
}

# proxmox_pool_membership (NOT the deprecated _virtual_environment_ alias). `type` is
# read-only — the provider infers lxc vs qemu from the vm_id — so only pool_id + vm_id are set.
resource "proxmox_pool_membership" "lxc" {
  for_each = local.pool_lxc_members

  pool_id = proxmox_virtual_environment_pool.homelab.pool_id
  vm_id   = each.value
}
