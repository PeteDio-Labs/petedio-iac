# Lab Villains decoys (PET-954): eight tiny throwaway containers that chaos tests may break.
#
# Two separate universes, so Joker and Thanos never share victims (guard.py reads the group):
#   dc      Joker's  250-253  decoy-dc-<vmid>
#   marvel  Thanos'  210-213  decoy-marvel-<vmid>
# Every decoy is listed in scripts/villain/targets.txt with tier `decoy`. No real service is in
# either group. A real service joins a group only by a PR that Pedro approves in plain words.
#
# Terraform owns existence, size and network only. A decoy runs nothing but sshd, so its health
# check is a Kuma TCP monitor on :22 (a Mac host step on PET-954, because Kuma on pete-pi-1 has no
# CI deploy). Joker's `kill-service` fault stops sshd, so a down monitor proves detection.
#
# WHY THESE NUMBERS. VMID = last IP octet, as everywhere here, so a VMID must be 1 to 254.
# 250 to 253 follow staging (249). Only five numbers above 249 are valid hosts, so Thanos' four
# sit at 210 to 213. All eight were absent from `lab_list_guests` and unreferenced in this repo
# on 2026-11-19. Confirm the router's DHCP pool excludes 210 to 213 and 250 to 253 before you merge.
# Confirm no live guest holds one of them before you apply.
#
# The three fields that have each broken a container here, as staging.tf lists: datastore_id
# "local", bridge vmbr0 (the module default), and a template present on the node.

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

module "decoy" {
  source   = "../../modules/proxmox-lxc"
  for_each = local.villain_decoys

  vm_id        = tonumber(each.key)
  hostname     = "decoy-${each.value.group}-${each.key}"
  ipv4_address = "192.168.50.${each.key}/24"

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
  description = "VMID by group for the Lab Villains decoys."
  value       = { for k, m in module.decoy : k => { vm_id = m.vm_id, group = local.villain_decoys[k].group } }
}
