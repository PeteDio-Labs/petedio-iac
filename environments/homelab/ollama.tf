# ollama-host (.12) — bare-metal dual-GPU box (GTX 1660 SUPER + RTX 3060 Ti)
# running Ollama (gemma4:e4b), brought under IaC the bare-metal way: Terraform
# DECLARES the host (this file, via modules/baremetal-host); Ansible OWNS the
# OS/IP config — netplan renumber .59 -> .12, NVIDIA 550, Ollama + model — in
# ../../ansible (roles/ollama-service, roles/ollama-models, playbooks/).
#
# Addressing: grouped with the bare-metal Proxmox hosts (pve01 .10, pve02 .11)
# as the next physical host, .12 — NOT the .24x compute block (.240 was already
# taken on the LAN). TF can't create a physical machine, and this homelab has no
# TF-manageable DNS/firewall (internal DNS retired; firewall is Ansible UFW), so
# TF's role is the host-declaration + the .12 desired-state.
#
# The live .59 -> .12 renumber was performed via the gated MANUAL play
# ../../ansible/playbooks/set-ollama-static-ip.yml (auto-revert safe) — NOT
# apply-on-merge. Applying this file only writes a terraform_data record to state.

module "ollama_host" {
  source = "../../modules/baremetal-host"

  hostname     = "ollama-host"
  ipv4_address = "192.168.50.12"
  mac_address  = "2c:f0:5d:a2:7f:4f"
  description  = "Bare-metal dual-GPU host (GTX 1660 SUPER + RTX 3060 Ti) running Ollama (gemma4:e4b). OS/IP config by Ansible (../../ansible)."

  # run_ansible intentionally left at its default (false): the renumber + OS
  # config are run manually/gated. See the header and ../../ansible/README.md.
}

output "ollama_host_ip" {
  description = "Static IPv4 of the ollama host (with the pve bare-metal hosts, .12)."
  value       = module.ollama_host.ipv4_address
}
