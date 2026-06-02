# poker-api (LXC 230) — EC2-equivalent Docker host for the Co-latro poker API.
# First consumer of the reusable modules/proxmox-lxc module. VMID 230 = apps
# block (.230), VMID = last IP octet.
#
# TF owns existence + hardware + network only. Docker + the nesting/keyctl
# container features needed to run it are configured by Ansible post-create —
# Proxmox's root@pam check rejects API tokens for the `features` mutation, so the
# module leaves `features` out and keeps it in ignore_changes (see docs/GOTCHAS.md).

module "poker_api" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 230
  hostname         = "poker-api-230"
  ipv4_address     = "192.168.50.230/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 2
  memory_dedicated = 2048
  description      = "Co-latro poker API Docker host. Managed by Terraform."
}

output "poker_api_id" {
  description = "VMID of the poker-api container."
  value       = module.poker_api.vm_id
}
