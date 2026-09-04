# plane (LXC 235) — self-hosted Plane, the tracker that replaces Linear.
#
# WHY THIS EXISTS. Linear was cut loose on 2026-08-13: the linear-code GitHub App was
# uninstalled, nothing was migrated, and the board was left as it stood. Plane Community
# Edition takes over. Full audit + decisions: the vault notes Projects/plane-cutover.md
# and Projects/plane-deploy.md.
#
# NO CLOUDFLARE ROUTE, DELIBERATELY — same reasoning as minio-data.tf. Plane is reached
# over the tailnet ([[244-tailscale]] advertises 192.168.50.0/24), never publicly. That is
# not a limitation, it is what makes the rest of the design simple: no CORS policy on the
# attachment bucket, no cache-bypass rule, no managed-transform fix, no Cloudflare 100 MB
# request-body cap silently 413-ing uploads, no /api/* Access bypass, and above all no
# UNGATED public MinIO S3 API (Access cannot gate a presigned-URL S3 client). Do not
# "fix" this by adding a cloudflare-routes.tf entry.
#
# The CI that moves work-item state on PR events runs on the SELF-HOSTED runners for the
# same reason — GitHub's hosted runners cannot reach a LAN-only Plane, and do not need to.
# See .github/workflows/plane-sync.yml.
#
# DATABASE IS EXTERNAL: the `plane` database on postgres-rds-231, declared in databases.tf
# like every other one. Redis and RabbitMQ stay bundled in Plane's compose — they hold no
# durable state worth a separate backup path. Attachments go to the `plane` bucket on the
# APP-DATA MinIO (245), never the tfstate one (221).
#
# DOCKER HOST — needs the features dance. Plane ships as ~10 containers, so unlike
# minio-data-245 (native systemd, deliberately) there is no non-Docker option. Proxmox's
# hardcoded root@pam check rejects API tokens for the features{} mutation, so this module
# creates the LXC WITHOUT features (kept in ignore_changes) and scripts/lxc-features-235.sh
# applies nesting=1,keyctl=1 over SSH-as-root on the node. Same as openfaas-241.
# See docs/GOTCHAS.md.
#
# VMID 235 = next free in the 23x apps block (234 is free but was palworld's and is still
# referenced by tickets and the runbook — reusing it would be confusing). VMID = last IP
# octet, as everywhere else.
#
# Debian 13 (module default template) — must exist on pve01's `local` storage or
# apply-on-merge fails at create:
#   pveam update && pveam download local debian-13-standard_13.1-2_amd64.tar.zst
#
# Sized against real headroom: pve01 has ~107 GiB RAM free and 218 GiB on sdb3-storage.
# The root disk goes on sdb3-storage, NOT local-lvm — local-lvm had only ~42 GiB free and
# a tracker's attachments plus Docker images would eat it.

module "plane" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 235
  hostname         = "plane-235"
  ipv4_address     = "192.168.50.235/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 4
  memory_dedicated = 8192
  memory_swap      = 2048
  disk_size        = 40
  # ⚠ Was sdb3-storage. That LVM group lived on pve01's sdb and is pinned
  # `nodes pve01` in storage.cfg, so it resolves to a node that no longer
  # exists. This container actually runs on local-lvm. Because `disk` is not in
  # the module's ignore_changes, leaving the dead value here reads as a
  # REPLACEMENT of a live container.
  datastore_id = "local-lvm"
  description  = "Plane CE — the issue tracker (replaces Linear). Tailnet-only, no public route. Managed by Terraform."
}

output "plane_id" {
  description = "VMID of the Plane container."
  value       = module.plane.vm_id
}
