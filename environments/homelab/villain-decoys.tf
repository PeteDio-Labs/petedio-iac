# Lab Villains decoys (PET-954): eight tiny throwaway containers that chaos tests may break.
#
# Two separate universes, so Joker and Thanos never share victims (guard.py reads the group):
#   dc      Joker's  250-253  decoy-dc-<vmid>
#   marvel  Thanos'  210-213  decoy-marvel-<vmid>
# Every decoy is listed in scripts/villain/targets.txt with tier `decoy`. No real service is in
# either group. A real service joins a group only by a PR that Pedro approves in plain words.
#
# THE NETWORK. The decoys sit on a private bridge, vmbr66, on 10.66.0.0/24: no router, no DHCP and
# no route to the LAN. Their address is 10.66.0.<vmid> and is static, so a decoy never waits on the
# gateway to boot. decoy-gw-214 is the gateway: one leg on the LAN (192.168.50.214), one on vmbr66
# (10.66.0.1). It forwards LAN port 10<vmid> to a decoy's sshd and lets a decoy start no connection
# (ansible/roles/decoy-gw). The gateway is on the denylist and never a target.
#
# Terraform owns existence, size and network only. A decoy runs nothing but sshd, so its health
# check is a Kuma TCP monitor on the gateway's forwarded port. Joker's `kill-service` fault stops
# sshd, so a down monitor proves detection.
#
# ORDER. The bridge exists only after `ansible/playbooks/proxmox/configure-decoy-net.yml` runs on
# pve03, and a merge applies Terraform without running Ansible. Run that play BEFORE the merge, or
# the container creates fail on the missing bridge. After the apply, run
# `ansible/playbooks/services/configure-decoy-gw.yml` and the lxc-features play for pve03.
#
# WHY THESE NUMBERS. VMID = last address octet, as everywhere here, on the private /24 for the
# decoys and the LAN for the gateway. 214 and 250 to 253 were absent from `lab_list_guests` on
# 2026-11-19 and unreferenced in this repo. Confirm the router's DHCP pool excludes 192.168.50.214.
#
# The three fields that have each broken a container here, as staging.tf lists: datastore_id
# "local", the bridge, and a template present on the node.

locals {
  villain_decoys = {
    "250" = { group = "dc" }
    "251" = { group = "dc" }
    "252" = { group = "dc" }
    "253" = { group = "dc" }
    "210" = { group = "marvel" }
    "211" = { group = "marvel" }
    "212" = { group = "marvel" }
    "213" = { group = "marvel" }
  }
}

module "decoy_gw" {
  source = "../../modules/proxmox-lxc"

  vm_id        = 214
  hostname     = "decoy-gw-214"
  ipv4_address = "192.168.50.214/24"

  cores            = 1
  memory_dedicated = 256
  memory_swap      = 0
  disk_size        = 2

  datastore_id     = "local"
  target_node      = "pve03"
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  ssh_public_key   = var.ssh_public_key
  description      = "Lab Villains decoy gateway. LAN leg and the private decoy bridge vmbr66. Managed by Terraform; config by configure-decoy-gw.yml."

  secondary_network_interface = {
    name         = "eth1"
    bridge       = "vmbr66"
    ipv4_address = "10.66.0.1/24"
  }
}

module "decoy" {
  source   = "../../modules/proxmox-lxc"
  for_each = local.villain_decoys

  vm_id        = tonumber(each.key)
  hostname     = "decoy-${each.value.group}-${each.key}"
  ipv4_address = "10.66.0.${each.key}/24"
  gateway      = "10.66.0.1"
  bridge       = "vmbr66"
  dns_servers  = []

  cores            = 1
  memory_dedicated = 256
  memory_swap      = 0
  disk_size        = 2

  datastore_id     = "local"
  target_node      = "pve03"
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  ssh_public_key   = var.ssh_public_key
  description      = "Lab Villains decoy (${each.value.group}). Throwaway: chaos tests may stop it. Managed by Terraform."
}

output "villain_decoy_ids" {
  description = "VMID by group for the Lab Villains decoys, and the gateway's VMID."
  value = {
    gateway = module.decoy_gw.vm_id
    decoys  = { for k, m in module.decoy : k => { vm_id = m.vm_id, group = local.villain_decoys[k].group } }
  }
}
