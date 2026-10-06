# usaa (LXC 238) — the host for petedio-usaa, a private savings and trip tracker over the
# USAA bank ledger (PET-590, repo PeteDio-Labs/petedio-usaa).
#
# WHY 238 / .238
#
# 238 is the next free number in the 23x apps block, beside 230 poker-api, 231 postgres,
# 232/233 the runners, 234 palworld, 235 plane, 236 plex-gpu and 237 media-dash. It is
# free in vault/Hosts/hosts-inventory.md and in Terraform. VMID = last IP octet, as
# everywhere else here.
#
# WHERE THE PIECES LIVE. This file owns existence, hardware and network only. The rest
# is declared next to it:
#   databases.tf           the `usaa` database on postgres-rds-231
#   cloudflare-routes.tf   usaa.pdlab.dev (Access) and usaa-feed.pdlab.dev (one path)
#   playbooks/configure-usaa.yml   the binary, the env file and the systemd unit,
#                                  run by scripts/deploy-usaa.sh
#
# ⚠ THIS IS A GREENFIELD CREATE, LIKE media-dash.tf. The plan is SUPPOSED to say "1 to
# add" for the container. Check the three fields below that have each broken a container
# in this lab: datastore_id, target_node and template_file_id.

module "usaa" {
  source = "../../modules/proxmox-lxc"

  vm_id        = 238
  hostname     = "usaa-238"
  ipv4_address = "192.168.50.238/24"

  # One Bun process over a small Postgres database. It holds no library and no cache
  # worth sizing for, so 1 GiB is headroom. The ledger import (docs/runbooks/usaa-tracker.md)
  # briefly holds a SQLite copy on the 8 GiB disk.
  cores            = 2
  memory_dedicated = 1024
  disk_size        = 8

  # pve03 has NO LVM thin pool — it was installed as plain Debian on ext4, so local-lvm is
  # inactive there and a guest declared with it fails at migration AFTER copying the disk
  # (PET-334). Same reason media-dash.tf, palworld.tf and runner.tf pin "local".
  # Changing target_node or datastore_id later REPLACES the container on the bpg provider.
  datastore_id = "local"
  target_node  = "pve03"

  # ⚠ PIN THE TEMPLATE TO ONE pve03 ACTUALLY HAS. Templates live on each node's own
  # `local`, a directory store that is not shared. pve03 carries only
  # debian-13-standard_13.6-1_amd64.tar.zst; taking the module default fails the create
  # with "volume ... does not exist", on the apply-on-merge runner, after the merge.
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  ssh_public_key   = var.ssh_public_key

  # True, as on palworld.tf: the module sets `started = var.start_on_boot` and Terraform
  # manages run state, so false would stop a hand-started container on the next apply.
  start_on_boot = true

  description = "petedio-usaa — savings and trip tracker over the USAA ledger (PET-590). Managed by Terraform; app by configure-usaa.yml."
}

output "usaa_id" {
  description = "VMID of the usaa container."
  value       = module.usaa.vm_id
}
