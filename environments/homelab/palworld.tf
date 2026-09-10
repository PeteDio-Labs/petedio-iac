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
# ⚠ THE PLAYERS' ADDRESS IS NOT THIS ONE. Clients connect to 192.168.86.234 on the mesh;
# this container is 192.168.50.234 on the platform LAN, and pve03 NATs between them. The
# matching .50/.86 last octet is deliberate, so the two addresses read as one machine.
# See ansible/roles/palworld-mesh-nat for why a real .86 address is not possible here.

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

  # ⚠ FALSE, AND IT IS A PRODUCT DECISION, NOT A DEFAULT. The server starts when Pedro
  # starts it from the panel (decided 2026-08-18) — it does not come back by itself after
  # a power cut, and an unattended boot is how the node quietly loses 8 GiB overnight.
  #
  # The module sets `started = var.start_on_boot`, so this ALSO keeps the container
  # stopped in Terraform's eyes. That is what makes a hand-stop stick instead of reading
  # as drift the next apply-on-merge reverses — the trap that ordered the PET-266 cutover,
  # where a booted 234 would have re-grabbed the address the laptop was using.
  #
  # Enablement is separate and Ansible's: a DISABLED unit still starts on demand, which is
  # how the panel's `systemctl start palworld` works.
  start_on_boot = false

  description = "Palworld dedicated server (PET-381). Managed by Terraform; game + world by configure-palworld.yml. Players reach it at 192.168.86.234 via the NAT on pve03."
}

output "palworld_id" {
  description = "VMID of the Palworld container."
  value       = module.palworld.vm_id
}
