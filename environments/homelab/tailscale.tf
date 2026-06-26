# tailscale (LXC 244) — Tailscale subnet router. Advertises the whole LAN
# (192.168.50.0/24) into the tailnet so any Tailscale client (phone, laptop) can
# reach every homelab service by its LAN IP without a per-host install. (PET-188)
#
# Same split as the other app LXCs: TF owns existence + hardware + network; everything
# inside (the tailscale daemon, IP forwarding, `tailscale up --advertise-routes`) is
# Ansible — ansible/playbooks/configure-tailscale.yml + roles/tailscale-router.
#
# VMID 244 = next free after agent-loop (242); VMID = last IP octet (192.168.50.244).
# Debian 13 (module default template) — must exist on pve01's `local` storage or
# apply-on-merge fails at create (it is the greenfield default, so normally present):
#   pveam update && pveam download local debian-13-standard_13.1-2_amd64.tar.zst
#
# TWO out-of-band, post-create steps (the loop/CI cannot do these — Proxmox root@pam +
# the operator's Tailscale account):
#   1. TUN device: a subnet router needs /dev/net/tun, which an API token can't add to
#      an unprivileged LXC (root@pam check, same gotcha as features). Run
#      scripts/lxc-tun-244.sh on the node AFTER apply, BEFORE the Ansible play.
#   2. Auth key: tailscale up needs a key from the operator's tailnet. Stored at Vault
#      kv/services/tailscale (field auth_key) — path reference only, never in code. The
#      advertised route must then be APPROVED in the Tailscale admin console, and clients
#      must enable "use subnet routes". See roles/tailscale-router/README.md.

module "tailscale" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 244
  hostname         = "tailscale-244"
  ipv4_address     = "192.168.50.244/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 1
  memory_dedicated = 512
  memory_swap      = 512
  disk_size        = 8
  description      = "Tailscale subnet router (advertises 192.168.50.0/24). Managed by Terraform."
}

output "tailscale_id" {
  description = "VMID of the tailscale subnet-router container."
  value       = module.tailscale.vm_id
}
