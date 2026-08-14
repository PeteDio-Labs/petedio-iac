# minio-data (LXC 245) — the homelab's APP-DATA MinIO. Distinct from the state backend on
# .221 in one load-bearing way: this one IS Terraform-managed.
#
# WHY A SECOND MinIO AT ALL. .221 holds the Terraform state and is hand-managed BY DESIGN —
# Terraform cannot create the host that stores its own state (bootstrap circularity; see
# minio-state-backend.tf and the MinIO ADR, PET-102). That exception is load-bearing but it
# is also a ceiling: every app bucket parked on .221 inherits a host that TF can never
# create, plan, or rebuild, and shares a disk with `tfstate`. A SECOND MinIO has no such
# circularity — nothing in its own lifecycle depends on it — so it is ordinary IaC: real
# module, real plan, real apply-on-merge. App data goes here; `tfstate` stays alone on .221.
#
# FIRST TENANT: the `obsidian-fs-mcs` bucket, which backs Obsidian vault sync for the FS MCS
# coursework vault across Pedro's Mac / iPhone / iPad / PC. Reached over the tailnet, never
# publicly — see below. Additional app buckets belong here too; add them to the
# `minio_buckets` list in ansible/inventory/group_vars/minio_data.yml, not to .221.
#
# Same TF/Ansible split as every other app LXC: TF owns existence + hardware + network;
# everything inside (MinIO binaries, systemd unit, UFW, buckets, versioning, quotas) is
# Ansible — ansible/playbooks/configure-minio-data.yml + roles/minio (the SAME role that
# converges .221; it takes a bucket list, and .221's default is unchanged).
#
# VMID 245 = next free after tailscale (244); VMID = last IP octet (192.168.50.245). This
# claims 245, so the still-unbuilt notes-svc takes 246.
#
# Debian 13 (module default template) — must exist on pve01's `local` storage or
# apply-on-merge fails at create (it is the greenfield default, so normally present):
#   pveam update && pveam download local debian-13-standard_13.1-2_amd64.tar.zst
#
# NO out-of-band post-create step. MinIO runs as a NATIVE systemd unit, not Docker, so this
# host needs neither `features{}` (nesting/keyctl) nor a device passthrough — the two things
# a Proxmox API token cannot set (hardcoded root@pam check, docs/GOTCHAS.md). That is a
# deliberate reason to keep MinIO un-containerized here: 244 needed scripts/lxc-tun-244.sh
# before its play could run, and this host needs nothing.
#
# NO CLOUDFLARE ROUTE, DELIBERATELY. There is no entry in cloudflare-routes.tf and there
# should not be. Cloudflare Access authenticates a browser (redirect + session) or a caller
# that can set CF-Access-Client-Id/Secret headers; an S3 client such as the Obsidian sync
# plugin does neither, so a CF route to :9000 would have to be UNGATED and public — strictly
# worse than what already exists. tailscale-244 already advertises 192.168.50.0/24 into the
# tailnet, so every client reaches this host by its LAN IP inside WireGuard with zero public
# ingress. Client setup: docs/runbooks/obsidian-vault-sync.md.
#
# In pool.tf: this LXC is in local.pool_lxc_members, along with waterfast-243 / tailscale-244
# — the three had been left out on the "follow the existing precedent" argument, which just
# propagated the drift. Membership is still gated behind var.manage_resource_pool.

module "minio_data" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 245
  hostname         = "minio-data-245"
  ipv4_address     = "192.168.50.245/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 1
  memory_dedicated = 1024
  memory_swap      = 512
  disk_size        = 16
  description      = "MinIO app-data object store (NOT the TF state backend — that is .221). Managed by Terraform."
}

output "minio_data_id" {
  description = "VMID of the app-data MinIO container."
  value       = module.minio_data.vm_id
}
