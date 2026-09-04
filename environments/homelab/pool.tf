# Proxmox resource pool grouping EVERY LXC on the cluster (PET-56). Org hygiene only —
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
  comment = "Every LXC on the cluster. Managed by Terraform (PET-56)."
}

locals {
  # vm_id sourced from each module's output → an implicit dependency, so a membership is
  # created after its container exists. Imported/captured LXCs (e.g. nexus) are included too:
  # membership is additive and never mutates the container. Gated by the same flag as the
  # pool itself.
  #
  # This map must list EVERY proxmox-lxc module in this environment — the pool's whole point
  # is that it accounts for every container, so a module missing here is silent drift. It had drifted
  # once already: authentik-119 and runner-233 were left out after their PRs merged (this file
  # still carried the "will be added when their PRs merge" TODO), and tailscale-244 /
  # minio-data-245 followed that precedent. When you add a proxmox-lxc module,
  # add it here in the same PR. ollama-host is NOT here on purpose — it is bare metal
  # (modules/baremetal-host), not a container, so it has no VMID to put in a pool.
  pool_lxc_members = var.manage_resource_pool ? {
    # registry and tailscale are no longer declared — see their .tf files.
    vault      = module.vault.vm_id
    poker_api  = module.poker_api.vm_id
    postgres   = module.postgres_host.vm_id
    runner     = module.runner.vm_id
    runner_2   = module.runner_2.vm_id
    openfaas   = module.openfaas.vm_id
    authentik  = module.authentik.vm_id
    minio_data = module.minio_data.vm_id
  } : {}

  # LXCs that exist on the cluster but have NO Terraform module here, so there is
  # no module output to source a vm_id from. Membership is additive and never
  # touches the container, so pooling them is safe even though TF does not manage
  # them — and leaving them out is precisely the "silent drift" this file warns
  # about, just one level up: the pool looked complete while a third of the
  # cluster sat outside it.
  #
  # Each of these is unmanaged for its own reason, not by oversight:
  #   221 minio      the Terraform S3 STATE BACKEND. TF cannot create the host
  #                  that stores TF state — see minio-state-backend.tf. Config-as-
  #                  code only, via configure-minio.yml.
  #   102 flaresolverr  pve02. Community-script container, never captured.
  #   112 cloud-flare-main  pve02. The cloudflared tunnel connector.
  #
  # The seven MEDIA LXCs (100/101/103/104/105/109/110) are deliberately NOT here:
  # they are Terraform-managed, just in a different repo and state
  # (petedio-media-iac). Hardcoding their VMIDs here would duplicate ownership and
  # lose the module dependency; that repo adds its own memberships to this pool
  # instead. This pool is cluster-wide, so cross-state membership is fine.
  pool_unmanaged_members = var.manage_resource_pool ? {
    minio            = 221
    flaresolverr     = 102
    cloud_flare_main = 112
  } : {}
}

# proxmox_pool_membership (NOT the deprecated _virtual_environment_ alias). `type` is
# read-only — the provider infers lxc vs qemu from the vm_id — so only pool_id + vm_id are set.
resource "proxmox_pool_membership" "lxc" {
  for_each = merge(local.pool_lxc_members, local.pool_unmanaged_members)

  pool_id = proxmox_virtual_environment_pool.homelab[0].pool_id
  vm_id   = each.value
}

# `proxmox_pool_membership.lxc` is a for_each over the map above, so renaming the
# key changes that member's address from ["nexus"] to ["registry"]. Pool
# membership is additive and never mutates the container, so a churn here is
# harmless — but it is still noise in the plan, and noise is how a real change
# hides. Re-address it explicitly (PET-301).
moved {
  from = proxmox_pool_membership.lxc["nexus"]
  to   = proxmox_pool_membership.lxc["registry"]
}
