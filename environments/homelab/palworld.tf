# palworld (LXC 234) — the game server, back as a container on pve03 (PET-381).
#
# WHY THIS FILE EXISTS AGAIN. It was DELETED on 2026-07-26 (iac#191) as the retirement
# path for the PET-266 move to bare metal. That bare-metal host was the ex-mission-control
# HP Spectre at 192.168.86.234 — and that laptop was wiped and rebuilt as pve03 itself on
# 2026-09-04 after pve01 died. So the game lost its host to the rack rebuild, not to a
# decision. This brings it back to where it started.
#
# ⚠ 234 IS DELIBERATE, AND media-dash.tf's WARNING DOES NOT FORBID IT. That file skipped
# 234 because "reusing 234 would collide two machines onto one note" — the note being
# vault/Hosts/234-palworld.md, which is keyed to VMID *and named for this service*.
# Handing 234 to media-dash would have collided two machines; handing it back to Palworld
# is the same machine returning, and every ticket that says "234" still means this one.
#
# ⚠ THE PLAYERS' ADDRESS IS NOT THIS ONE. Clients connect to pve03's mesh address —
# 192.168.86.244 — and pve03 NATs to this container on 192.168.50.234. See
# ansible/roles/palworld-mesh-nat for why a real .86 address is not possible here, and
# why .244 rather than the old server's .234.

module "palworld" {
  source = "../../modules/proxmox-lxc"

  vm_id        = 234
  hostname     = "palworld-234"
  ipv4_address = "192.168.50.234/24"

  # ⚠ SIZED AGAINST A NODE THAT IS NOW SHARED, WHICH IT WAS NOT BEFORE. On bare metal
  # Palworld had all 15 GiB of this laptop to itself. pve03 now runs 15 other guests on
  # the same 15 GiB — Vault, Postgres, Plane, MinIO, Authentik, the arr stack and a CI
  # runner — with about 9.4 GiB genuinely available (measured 2026-09-09; the 33 GiB
  # already "allocated" is caps, not reservations, and only ~6 GiB is in use).
  #
  # 8 GiB is a CAP that leaves the node a working margin, not a reservation. The cost is
  # only paid while the server runs, because start_on_boot is false below.
  #
  # CPU is not the worry: pve03 IS the laptop that served this world at 59 fps with two
  # players (the old LXC on pve01's Xeon E5-2690 v2 managed 21). Palworld is single-thread
  # bound and this is the fastest clock in the fleet.
  cores            = 4
  memory_dedicated = 8192

  # SteamCMD plus app 2394010 is 12-15 GB before the world; 40 leaves room for an update
  # staging its own copy, which is how the app updates in place.
  disk_size = 40

  # pve03 has NO LVM thin pool — it was installed as plain Debian on ext4, so local-lvm is
  # inactive there and a guest declared with it fails at migration AFTER copying the disk
  # (PET-334). Same reason media-dash.tf and runner.tf pin "local".
  datastore_id = "local"
  target_node  = "pve03"

  # ⚠ PIN THE TEMPLATE TO ONE pve03 ACTUALLY HAS. Templates live on each node's own
  # `local`, a directory store that is not shared. pve03 carries exactly one:
  # debian-13-standard_13.6-1_amd64.tar.zst (checked 2026-09-09). Taking the module
  # default fails the create with "volume ... does not exist", on the apply-on-merge
  # runner, after the merge.
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  ssh_public_key   = var.ssh_public_key

  # ⚠ TRUE, AND THE CONTAINER IS NOT THE GAME. This was false on the first pass, reasoning
  # that "the server starts when Pedro starts it" (decided 2026-08-18) meant the container
  # should stay down. That conflates two things, and getting it wrong is dangerous here.
  #
  # The module sets `started = var.start_on_boot` and `started` is NOT in ignore_changes,
  # so Terraform ACTIVELY MANAGES RUN STATE. With false, a container started to play on
  # is drift, and the next apply-on-merge — triggered by any unrelated change in this
  # repo — STOPS IT MID-GAME. That is the PET-266 trap inverted: there, a hand-stopped
  # 234 was drift and an apply booted it back up to collide with the laptop's address.
  #
  # What actually implements the 2026-08-18 decision is Ansible, not this flag:
  # palworld_service_autostart=false leaves palworld.service DISABLED, so the game does
  # not start with the container. A disabled unit still starts on demand, which is how
  # the panel's `systemctl start palworld` works.
  #
  # The cost of leaving the container up is measured, not assumed: an idle palworld-234
  # uses 16 MiB, and pve03 still reported 9.2 GiB available with it running (2026-09-09).
  # memory_dedicated above is a cgroup CAP, not a reservation — the 8 GiB is only occupied
  # while the game itself runs.
  start_on_boot = true

  description = "Palworld dedicated server (PET-381). Managed by Terraform; game + world by configure-palworld.yml. Players reach it at 192.168.86.244 via the NAT on pve03."
}

output "palworld_id" {
  description = "VMID of the Palworld container."
  value       = module.palworld.vm_id
}
