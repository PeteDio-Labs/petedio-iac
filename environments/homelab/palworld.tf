# palworld (LXC 234) — Palworld 1.0 dedicated game server. (PET-157)
#
# Greenfield game host, prepped so launch day (2026-07-10) is just "install the
# binaries + enable the unit". TF owns existence + hardware + network; the
# `palworld` Ansible role (configure-palworld.yml) owns everything inside EXCEPT
# the game binaries (SteamCMD app 2394010 — operator runs that on/after launch,
# since the 1.0 build doesn't exist until then). Native SteamCMD server — no
# Docker, so no nesting/keyctl features (the cleanest LXC pattern, like nexus/runner).
#
# Sized per Pocketpair's 1.0 guidance: 16 GB RAM, fast disk for the doubled map's
# saves/I-O. Palworld is single-thread bound (clock > core count).
#
# >>> OPERATOR — confirm these host-specific values before `terraform apply` (the
#     loop can't see the live node, and TF never applies here):
#   - vm_id / ipv4_address: 234 / .234 is the proposed apps-block slot (.230-.233
#     used, .240 burned). CONFIRM against the Homelab Inventory & IP/VMID Scheme,
#     and add the STATIC DHCP lease on the router (operator-only — hard rule 6).
#   - datastore_id: the issue wants the NVMe pool for save I/O. The module default
#     is the SSD `sdb3-storage`; set this to the NVMe datastore id (`pvesm status`
#     on pve01) before apply. Left explicit below as a reminder.
#   - CPU affinity: pin the container to the highest-clock physical cores after
#     create (`pct set 234 --cores <n>` is set here; physical-core *affinity* is
#     host-topology-specific — `pct set 234 --cpulimit`/`--cpuunits` or a cgroup
#     affinity, operator tunable). `cores = 4` gives headroom for the single hot thread.

module "palworld" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 234
  hostname         = "palworld-234"
  ipv4_address     = "192.168.50.234/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 4
  memory_dedicated = 16384 # 16 GB — Pocketpair's 1.0 recommendation
  memory_swap      = 2048
  disk_size        = 40 # ~12-15 GB binaries + 1.0 saves + headroom
  # OPERATOR: switch to the NVMe pool datastore id (see header). `sdb3-storage` is
  # the known-valid SSD default so a mistaken apply fails safe rather than 404s on a
  # guessed pool name; the issue requires NVMe for save I/O.
  datastore_id = "sdb3-storage"
  description  = "Palworld 1.0 dedicated server (PET-157). Managed by Terraform."
}

output "palworld_id" {
  description = "VMID of the Palworld dedicated-server container."
  value       = module.palworld.vm_id
}
