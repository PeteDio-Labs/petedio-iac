# vault (LXC 223) — the Secrets-Manager-equivalent (HashiCorp Vault) host.
# VMID 223 = core block (.223), VMID = last IP octet. Consumes the reusable
# modules/proxmox-lxc module.
#
# FRESH BUILD — this replaces the old secrets-host (LXC 121) from the retired
# homelab-infra repo (being destroyed). It is NOT an import: TF creates a new
# container and owns existence + hardware + network only.
#
# Vault itself — install, raft storage, TLS, and the nesting/keyctl container
# features — comes from Ansible post-create (ansible/playbooks/configure-vault.yml).
# Proxmox's root@pam check rejects API tokens for the `features` mutation, so the
# module leaves `features` out and keeps it in ignore_changes (see docs/GOTCHAS.md).

module "vault" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 223
  hostname         = "vault-223"
  ipv4_address     = "192.168.50.223/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 2
  memory_dedicated = 2048
  disk_size        = 20
  description      = "HashiCorp Vault (Secrets Manager). Managed by Terraform."
}

output "vault_id" {
  description = "VMID of the vault container."
  value       = module.vault.vm_id
}

output "vault_ip" {
  description = "Static IPv4 address (CIDR) of the vault container."
  value       = module.vault.ipv4_address
}
