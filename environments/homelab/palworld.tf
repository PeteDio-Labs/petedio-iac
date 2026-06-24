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
#   - datastore_id: PET-157 wanted an NVMe pool for save I/O, but pve01 (target_node)
#     has NO NVMe — `sdb3-storage` is an SSD-backed LVM pool (it reads `ROTA=1` in
#     lsblk, but that's a PERC H710 hardware-RAID artifact, not spinning media). The
#     cluster's only NVMe is on pve02. Decision (PET-157): keep `sdb3-storage` (SSD)
#     on pve01 for now; revisit NVMe (move to pve02 or add a pool) as a follow-up.
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
  # `sdb3-storage` is pve01's SSD-backed LVM pool (lsblk shows ROTA=1, but that's a
  # PERC H710 RAID artifact — it's an SSD). PET-157 wanted NVMe for save I/O, but
  # pve01 has no NVMe (cluster NVMe is on pve02), so keep sdb3-storage and defer
  # NVMe to a follow-up. See header.
  datastore_id = "sdb3-storage"
  description  = "Palworld 1.0 dedicated server (PET-157). Managed by Terraform."

  # PET-168: dual-home onto the 192.168.86.x mesh for local-LAN play, ALONGSIDE the
  # platform-LAN NIC (eth0, .50.234) and the Tailscale path — those are untouched. No
  # gateway here: the default route stays on eth0. The launch-day install/enable is still
  # the operator's (PET-157 carryover).
  # >>> OPERATOR — confirm before apply (loop can't see the node; never applies):
  #   - bridge: the Proxmox bridge for the .86 mesh on pve01. pve01 has vmbr1 (LAN .50 +
  #     gateway) and vmbr0 (no gateway) — set this to whichever bridges the .86 mesh
  #     segment (`ip -br link` / `cat /etc/network/interfaces` on pve01). Placeholder vmbr0.
  #   - ipv4_address + the STATIC DHCP lease on the .86 mesh (router/DHCP = hard rule 6,
  #     operator). .34 is a placeholder — confirm a free mesh address.
  secondary_network_interface = {
    name         = "eth1"
    bridge       = "vmbr0"
    ipv4_address = "192.168.86.34/24"
    # no ipv4_gateway — default route stays on eth0 (platform LAN)
  }
}

output "palworld_id" {
  description = "VMID of the Palworld dedicated-server container."
  value       = module.palworld.vm_id
}
