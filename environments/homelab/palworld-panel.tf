# palworld-panel (LXC 235) — Docker host for the Palworld control panel (PET-266).
# Small web app (Bun backend + static SPA, from Nexus) that gracefully shuts down /
# starts the Palworld server (234) and shows live status. Public at palworld.pdlab.dev,
# gated by Cloudflare Access + Authentik (see cloudflare-routes.tf).
#
# VMID 235 = next free slot after the game server (234); VMID == last IP octet. Like
# poker-api (230), TF owns existence + hardware + network only — Docker + the nesting/
# keyctl features are set post-create by Ansible / scripts/lxc-features-235.sh (the
# root@pam/API-token gotcha; the module keeps `features` in ignore_changes — GOTCHAS.md).
#
# >>> OPERATOR — before/after apply:
#   - Add the STATIC DHCP reservation for .235 on the router (hard rule 6, operator-only).
#   - After apply: run scripts/lxc-features-235.sh (nesting for Docker), then deploy with
#     scripts/deploy-palworld-panel.sh (needs the panel images published to Nexus first).

module "palworld_panel" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 235
  hostname         = "palworld-panel-235"
  ipv4_address     = "192.168.50.235/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 2
  memory_dedicated = 2048
  description      = "Palworld control-panel Docker host (PET-266). Managed by Terraform."
}

output "palworld_panel_id" {
  description = "VMID of the Palworld control-panel container."
  value       = module.palworld_panel.vm_id
}
