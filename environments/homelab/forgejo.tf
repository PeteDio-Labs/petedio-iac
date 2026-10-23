# forgejo (LXC 249): a read-only local mirror of every PeteDio-Labs repo (PET-756).
#
# GitHub stays the source of truth. This host holds a copy for offline backup and fast LAN
# clones (claude-247, petedio-search). It is reachable on the LAN and, through pete-pi-1's
# subnet route, on the tailnet. There is no Cloudflare route and no port forward.
#
# WHY 249 / .249. 241-243 are destroyed numbers and 244 is down, 246 is reserved for notes-svc
# (minio-data.tf), and 247 and 248 are claude and codex. 249 is free in
# vault/Hosts/hosts-inventory.md and in Terraform. VMID = last IP octet, as everywhere else here.
#
# WHERE THE PIECES LIVE. This file owns existence, hardware and network only.
#   playbooks/configure-forgejo-mirror.yml   Forgejo, the sync script and its timer,
#                                            run by scripts/deploy-forgejo-mirror.sh
#   scripts/seed-forgejo-mirror-vault.sh     the read-only GitHub App key in Vault
#
# ⚠ THIS IS A GREENFIELD CREATE. The plan is SUPPOSED to say "1 to add" for the container.
# Check the three fields below that have each broken a container in this lab: datastore_id,
# target_node and template_file_id.

module "forgejo" {
  source = "../../modules/proxmox-lxc"

  vm_id        = 249
  hostname     = "forgejo-249"
  ipv4_address = "192.168.50.249/24"

  # One Go binary over SQLite. The mirror holds bare copies of about a dozen small repos.
  cores            = 2
  memory_dedicated = 1024
  disk_size        = 16

  # pve03 has NO LVM thin pool (PET-334), so a guest declared with local-lvm fails at migration
  # after copying the disk. Changing target_node or datastore_id later REPLACES the container.
  datastore_id = "local"
  target_node  = "pve03"

  # ⚠ PIN THE TEMPLATE TO ONE pve03 ACTUALLY HAS. Templates live on each node's own `local`.
  # pve03 carries only debian-13-standard_13.6-1_amd64.tar.zst (see usaa.tf).
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  ssh_public_key   = var.ssh_public_key

  # True, as on usaa.tf: the module sets `started = var.start_on_boot` and Terraform manages run
  # state, so false would stop a hand-started container on the next apply.
  start_on_boot = true

  description = "Forgejo read-only mirror of PeteDio-Labs (PET-756). Managed by Terraform; app by configure-forgejo-mirror.yml."
}

output "forgejo_id" {
  description = "VMID of the forgejo mirror container."
  value       = module.forgejo.vm_id
}
