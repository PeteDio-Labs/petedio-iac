# ollama-host (compute/AI block — .240) — bare-metal dual-GPU box (GTX 1660 SUPER
# + RTX 3060 Ti) running Ollama (gemma4:e4b), brought under IaC the bare-metal
# way: Terraform DECLARES
# the host (this file, via modules/baremetal-host); Ansible OWNS the OS/IP config
# — netplan renumber .59 -> .240, NVIDIA driver 550, Ollama + model — in
# ../../ansible (roles/ollama-service, roles/ollama-models, playbooks/).
#
# TF can't create a physical machine, and this homelab has no TF-manageable
# DNS/firewall (internal DNS retired; firewall is Ansible UFW), so TF's role here
# is the host-declaration + the .240 desired-state. Identity 240 = last IP octet
# (the bare-metal equivalent of the VMID = last-octet scheme).
#
# THE LIVE .59 -> .240 RENUMBER IS A GATED MANUAL STEP (run_ansible defaults
# false): run ../../ansible/playbooks/set-ollama-static-ip.yml (it has an
# auto-revert safety timer) from the Mac or pve01, with Wake-on-LAN as the
# recovery path, then update the router DHCP reservation (MAC
# 2c:f0:5d:a2:7f:4f -> .240). NOT apply-on-merge — applying this file alone
# touches nothing on the host (it only writes a terraform_data record to state).

module "ollama_host" {
  source = "../../modules/baremetal-host"

  hostname     = "ollama-host"
  ipv4_address = "192.168.50.240"
  mac_address  = "2c:f0:5d:a2:7f:4f"
  description  = "Bare-metal dual-GPU host (GTX 1660 SUPER + RTX 3060 Ti) running Ollama (gemma4:e4b). OS/IP config by Ansible (../../ansible)."

  # run_ansible intentionally left at its default (false): the renumber + OS
  # config are run manually/gated. See the header and ../../ansible/README.md.
}

output "ollama_host_ip" {
  description = "Static IPv4 of the ollama host (compute block .240)."
  value       = module.ollama_host.ipv4_address
}
