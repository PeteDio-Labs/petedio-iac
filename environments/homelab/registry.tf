# nexus-registry (LXC 106 / .111) — the homelab Docker/Maven registry behind
# registry.pdlab.dev + docker.pdlab.dev. A permanent KEEP host (PET-101 → PET-122):
# its edge route and creds (kv/services/nexus) were already in TF/Vault; this brings
# the HOST itself under petedio-iac as a brownfield capture — captured IN PLACE, zero
# disruption (the blob store is a load-bearing NFS mount; never recreate this LXC).
#
# This is an UNUSUAL consumer of modules/proxmox-lxc — it was created out-of-band by a
# community-scripts "Docker LXC", not by this module, so it diverges from the greenfield
# defaults. The module gained backward-compatible knobs (PET-122) to capture it exactly:
#   - network_interface_name = "eth1"  (the running NIC name; default is eth0)
#   - mac_address pinned to the running hwaddr  (so the import doesn't churn the NIC)
#   - dns_servers = []  (CT106 sets no nameserver/searchdomain — inherits host resolv.conf)
# and the module ignores `mount_point` (CT106's mp0 /mnt/pete/nexus-data -> /nexus-data is
# a host-path bind mount of pve02's NFS export — set out-of-band on the node like features;
# the API token can't manage it). features (nesting,keyctl), the lxc.idmap (host 200 ↔
# guest 200 — what makes that mount writable in-guest) and console are likewise out-of-band
# and held in the module's ignore_changes: bpg round-trips idmap/console on import, so
# without the ignore the first plan tries to strip them. Only the raw apparmor line is
# truly invisible to the provider. See docs/GOTCHAS.md.
#
# Values below are the LIVE config, read read-only via scripts/proxmox-ro-config.sh pve01 106
# (PVEAuditor token — no mutation) so the import plans as a no-op without guessing specs.
#
# IMPORT-ONLY (operator, see docs/runbooks/registry-import.md — the loop never imports/applies):
#   terraform -chdir=environments/homelab import \
#     'module.registry.proxmox_virtual_environment_container.this' pve01/106
# then `terraform plan` MUST be a no-op (modulo the documented cosmetic description/tags
# fields). Any add/change/destroy of the LXC, NIC, or mount is a STOP-and-reassess.

# ---------------------------------------------------------------------- moved --
# Renaming a module changes its RESOURCE ADDRESS, not just a label. Without this
# block Terraform reads `module.nexus` as deleted and `module.registry` as new,
# and plans to DESTROY AND RECREATE LXC 106 — a live registry with an NFS blob
# store. `moved` re-addresses it in state instead, so the plan shows no change.
#
# The old name is Nexus, the software this container stopped running on
# 2026-08-11 (PET-301). The storage-layer names — the `nexus-data` LV, the mount
# paths, and the hostname `nexus-registry` — deliberately still say nexus: those
# take the registry offline to change and are paired with the pve02 storage
# reshape, which recarves the LVs anyway. See vault Projects/registry-storage-reshape.
#
# Keep this block after the apply that consumes it. Removing it later re-plans
# the destroy for anyone whose state predates the rename.
moved {
  from = module.nexus
  to   = module.registry
}

module "registry" {
  source = "../../modules/proxmox-lxc"

  vm_id        = 106
  hostname     = "nexus-registry"
  ipv4_address = "192.168.50.111/24"
  target_node  = var.target_node

  # Was 4c/8G for Nexus's JVM. zot is a Go binary: after the swap this box idles
  # at ~120MB of 8192MB, so 2c/1G is generous. Memory is the real reclaim —
  # 7GB back to pve01.
  #
  # DISK STAYS AT 40G, deliberately. It is thick-provisioned (`-wi-ao----` on VG
  # `pve`, no thin pool), so the full 40G really is reserved for what now uses
  # 2.6G. Reclaiming it is not worth the risk:
  #   - `pct resize` cannot shrink, only grow. Proxmox does not support it.
  #   - A manual shrink (e2fsck -> resize2fs -> lvreduce) truncates the
  #     filesystem if the order or the size is wrong.
  #   - vzdump/destroy/restore-smaller is safer but destroys and recreates a
  #     Terraform-managed container, churning state for cosmetic gain.
  # VG `pve` has 218G free, so there is no pressure. The actual waste on this box
  # was an uncapped systemd journal at 3.5G — fixed in the zot role, which caps
  # it at 200M. Revisit only if the VG gets tight.
  cores = 2
  # 2048 (the as-imported value) livelocked the container in reclaim once the Nexus
  # JVM's effective -Xmx4g heap filled it (PET-272 outage: memory PSI some=98%,
  # 133B direct pgscans, CF 524 at the edge). JVM worst case is ~6.5G committed
  # (4g heap + 2g direct + metaspace), so 8192 leaves real headroom.
  memory_dedicated = 1024
  memory_swap      = 512
  disk_size        = 40
  datastore_id     = "sdb3-storage"
  bridge           = "vmbr1"

  # Brownfield divergences from the greenfield defaults (captured from live config):
  network_interface_name = "eth1"
  mac_address            = "BC:24:11:F0:6A:D5"
  dns_servers            = [] # CT106 sets no resolver config; matching it keeps the import a no-op

  # ssh_public_key feeds initialization.user_account, which the module keeps in
  # ignore_changes (bpg never round-trips it on import — see GOTCHAS); passing the
  # standard automation key keeps this consistent with the other LXCs.
  ssh_public_key = var.ssh_public_key

  description = "OCI registry (zot) at docker.pdlab.dev — LAN-only, no tunnel. Ex-Nexus; VMID/hostname kept to avoid a destroy+recreate. Managed by Terraform."
}

output "nexus_id" {
  description = "VMID of the registry container (zot, ex-Nexus)."
  value       = module.registry.vm_id
}
