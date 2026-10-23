# pve04 (.12) and ollama-246 (.246) — the GPU node and its Ollama container. PET-528.
#
# Until 2026-10-23 this file declared ollama-host: bare-metal Ubuntu with two GPUs,
# running Ollama natively, through modules/baremetal-host. Pedro reinstalled that box as
# the Proxmox node pve04 on a new 128 GB drive and joined it to the cluster. The two
# 1 TB disks were unplugged during the install, so the backup store and the recovered
# WD data came through untouched (docs/runbooks/pve04-cutover.md).
#
# THE NODE. Terraform cannot create a physical machine, so the node stays a
# terraform_data declaration of its identity and address, as before. The `moved` block
# renames the address with no change to state; the new hostname and description are
# an in-place update of the same terraform_data, not a replacement.
#
# THE CONTAINER. Ollama's two pinned lanes and petedio-search run in CT 246, which
# holds both GPUs as device nodes. Terraform creates it; Ansible owns what Proxmox lets
# only root@pam set:
#   - the devN GPU entries     roles/lxc-gpu, from playbooks/configure-pve04.yml
#   - nesting                   roles/lxc-features ("246" in its defaults)
#   - the driver userspace,     playbooks/configure-ollama-246.yml
#     Ollama and the models
# device_passthrough and features are both in the module's ignore_changes for that
# reason, so the plan stays clean whether Ansible has run or not.
#
# ⚠ MERGE ONLY AFTER pve04 HAS JOINED THE CLUSTER. Apply-on-merge creates CT 246 on
# pve04, and a target_node that does not resolve fails at refresh, on the runner, after
# the merge. The template must also be on pve04's own `local` store first:
# configure-pve04.yml copies it from pve03.

moved {
  from = module.ollama_host
  to   = module.pve04_host
}

module "pve04_host" {
  source = "../../modules/baremetal-host"

  hostname     = "pve04"
  ipv4_address = "192.168.50.12"
  mac_address  = "2c:f0:5d:a2:7f:4f"
  description  = "Proxmox node pve04 (ex ollama-host): Ryzen 5 5600X, 16 GB, RTX 3060 Ti + GTX 1660 SUPER. Holds CT 246 and the ollama-backups store. OS config by ../../ansible (configure-pve04.yml)."
}

module "ollama" {
  source = "../../modules/proxmox-lxc"

  vm_id        = 246
  hostname     = "ollama-246"
  ipv4_address = "192.168.50.246/24"

  # The models live in VRAM, so RAM covers the two Ollama processes, their page cache
  # and petedio-search. The node has 16 GB in all, and the Proxmox host and the NFS
  # export of the backup store need the rest. Ten of the 5600X's twelve threads: a
  # model that spills to the CPU is a fault lab-verify reports, not a workload to size for.
  cores            = 10
  memory_dedicated = 8192
  memory_swap      = 1024

  # The model store. qwen3:8b and qwen3-embedding:0.6b are about 6 GB; the rest is room
  # for the models host_vars may declare later, and petedio-search's index.
  disk_size = 80

  # pve04 was installed from the Proxmox ISO, so it has the LVM thin pool pve03 lacks.
  # Changing target_node or datastore_id later REPLACES the container on the bpg provider.
  datastore_id     = "local-lvm"
  target_node      = "pve04"
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  ssh_public_key   = var.ssh_public_key

  # True, as on usaa.tf: the module sets `started = var.start_on_boot` and Terraform
  # manages run state, so false would stop a hand-started container on the next apply.
  start_on_boot = true

  description = "Ollama (RTX 3060 Ti :11434, GTX 1660 SUPER :11435) and petedio-search :8526 (PET-528). Managed by Terraform; GPUs by configure-pve04.yml, services by configure-ollama-246.yml."
}

output "pve04_ip" {
  description = "Address of the Proxmox node pve04, which serves the ollama-backups NFS store."
  value       = module.pve04_host.ipv4_address
}

output "ollama_id" {
  description = "VMID of the Ollama container."
  value       = module.ollama.vm_id
}
