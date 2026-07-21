# resume-242 (LXC 242, ex agent-loop-242) — repurposed off the retired agent fleet
# (worker/engine/reviewer) into the host for the Sonia resume builder (PET-265 P0 /
# Resume Builder milestone, planning doc resume-builder-planning-cd7da4b423e9).
# Same VMID/IP (renumbering only happens on independent rebuilds); hostname renamed
# and RAM bumped 4G->6G to fit MongoDB + the SvelteKit app alongside what's already
# installed (Bun, vault-agent AppRole plumbing — kept, reusable as-is). Greenfield
# create via modules/proxmox-lxc: TF owns existence + hardware + network; app
# provisioning (Mongo, the SvelteKit deploy unit) is future Ansible (P1, not yet
# written — the old agent-loop role/playbooks were fleet-scoped and removed here).
#
# VMID 242 = compute/AI block (.242), VMID = last IP octet — the NEXT free number:
# .240 is skipped (stale router DHCP reservation on the LAN, the same one that pushed
# ollama-host to .12 — see the Inventory doc §3–4) and 241 = openfaas.
#
# Ubuntu LTS (24.04 noble) per PET-125 — the first non-Debian LXC here, hence the
# os_type override (the module default stays "debian").

module "agent_loop" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 242
  hostname         = "resume-242"
  ipv4_address     = "192.168.50.242/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 2
  memory_dedicated = 6144
  disk_size        = 32
  template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  os_type          = "ubuntu"
  description      = "Resume builder host (cv.pdlab.dev) — Bun/SvelteKit/MongoDB. Ex agent-loop. Managed by Terraform."
}

output "agent_loop_id" {
  description = "VMID of the agent-loop container."
  value       = module.agent_loop.vm_id
}
