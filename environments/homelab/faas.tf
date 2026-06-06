# openfaas (LXC 241) — homelab serverless (faasd) host for the Co-latro admin
# service functions (invite generation, announcements, feedback intake). PET-86.
#
# VMID 241 = compute/AI block (.24x), VMID = last IP octet. NB: .240 is recorded
# as already-taken on the LAN in ollama.tf (that's why ollama-host took .12), so
# OpenFaaS takes .241.
#
# Same split as poker-api: TF owns existence + hardware + network only. The
# nesting/keyctl container features (needed for containerd/faasd) are applied
# out-of-band by scripts/lxc-features-241.sh, and faasd itself is installed by
# ansible/playbooks/configure-openfaas.yml — Proxmox's root@pam check rejects API
# tokens for the `features` mutation, so the module leaves `features` out and keeps
# it in ignore_changes (see docs/GOTCHAS.md).

module "openfaas" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 241
  hostname         = "openfaas-241"
  ipv4_address     = "192.168.50.241/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 2
  memory_dedicated = 4096
  disk_size        = 30
  description      = "OpenFaaS (faasd) homelab serverless host. Managed by Terraform."
}

output "openfaas_id" {
  description = "VMID of the openfaas (faasd) container."
  value       = module.openfaas.vm_id
}
