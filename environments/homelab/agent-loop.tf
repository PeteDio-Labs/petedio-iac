# agent-loop (LXC 240) — autonomous coding loop host (PET-125): Claude Code working
# `agent-ok` issues. Greenfield create via modules/proxmox-lxc, same split as the
# other app LXCs: TF owns existence + hardware + network; everything inside (Node.js
# LTS, Claude Code, gh, the run-loop.sh skeleton) is Ansible —
# ansible/playbooks/configure-agent-loop.yml + roles/agent-loop. Reusing LXC 113 was
# rejected (renumbering = destroy+recreate anyway; the loop host is cattle, not pets)
# — 113 proceeds to teardown per PET-17.
#
# VMID 240 = compute/AI block (.240), VMID = last IP octet. NB: .240 was historically
# unusable on the LAN — a stale router DHCP reservation is what pushed ollama-host to
# .12 (see the Inventory doc §3–4). PET-125 reclaims it: confirm the router
# reservation is cleared/repointed BEFORE merging, or the host comes up into an
# address conflict.
#
# Ubuntu LTS (24.04 noble) per PET-125 — the first non-Debian LXC here, hence the
# os_type override (the module default stays "debian"). PRE-MERGE: the template must
# exist on pve01's `local` storage or apply-on-merge fails at create:
#   pveam update && pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
#
# No secrets in TF or Ansible for this host: the scoped GitHub token (push branches +
# open PRs only, no merge) lives in Vault at kv/services/agent-loop — path reference
# only, pulled onto the host manually post-merge. See ansible/roles/agent-loop/README.md
# for the full provisioning runbook (claude login, token pull, first supervised run).

module "agent_loop" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 240
  hostname         = "agent-loop-240"
  ipv4_address     = "192.168.50.240/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 2
  memory_dedicated = 4096
  disk_size        = 32
  template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  os_type          = "ubuntu"
  description      = "Agent loop host — Claude Code autonomous coding loop. Managed by Terraform."
}

output "agent_loop_id" {
  description = "VMID of the agent-loop container."
  value       = module.agent_loop.vm_id
}
