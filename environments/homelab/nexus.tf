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
# IMPORT-ONLY (operator, see docs/runbooks/nexus-import.md — the loop never imports/applies):
#   terraform -chdir=environments/homelab import \
#     'module.nexus.proxmox_virtual_environment_container.this' pve01/106
# then `terraform plan` MUST be a no-op (modulo the documented cosmetic description/tags
# fields). Any add/change/destroy of the LXC, NIC, or mount is a STOP-and-reassess.

module "nexus" {
  source = "../../modules/proxmox-lxc"

  vm_id        = 106
  hostname     = "nexus-registry"
  ipv4_address = "192.168.50.111/24"
  target_node  = var.target_node

  cores = 4
  # 2048 (the as-imported value) livelocked the container in reclaim once the Nexus
  # JVM's effective -Xmx4g heap filled it (PET-272 outage: memory PSI some=98%,
  # 133B direct pgscans, CF 524 at the edge). JVM worst case is ~6.5G committed
  # (4g heap + 2g direct + metaspace), so 8192 leaves real headroom.
  memory_dedicated = 8192
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

  description = "Nexus registry (registry.pdlab.dev / docker.pdlab.dev). Brownfield-captured into petedio-iac (PET-122). Managed by Terraform."
}

output "nexus_id" {
  description = "VMID of the Nexus registry container."
  value       = module.nexus.vm_id
}
