# media-dash (LXC 237) — the host for mtrace, the media stack's read-only control
# surface (PET-355, repo PeteDio-Labs/petedio-media-control).
#
# WHY 237 / .237, AND WHY IN THIS REPO
#
# 237 is the next free number in the 23x apps block, and this repo owns every guest in
# it (230 poker-api, 231 postgres, 232/233 the runners, 235 plane). mtrace runs no
# media service — it READS seerr, the *arr apps, qBittorrent and Plex over SSH — so it
# belongs with the applications, not in petedio-media-iac beside the things it
# inspects. VMID = last IP octet, as everywhere else here.
#
# ⚠ 234 WAS DELIBERATELY SKIPPED. palworld-234 was destroyed in 2026-07 and its vault
# note survives under that VMID key, because the machine notes are keyed on VMID and
# tickets still reference it. Reusing 234 would collide two machines onto one note.
#
# ⚠ THIS IS THE FIRST GREENFIELD CREATE THIS REPO HAS EVER PLANNED. Every other guest
# here arrived by `terraform import` off a running container, so every previous plan
# was a no-op by construction and a non-empty diff meant drift. This one is SUPPOSED
# to say "1 to add". Read the plan before merging it and check the three fields below
# that have each broken a container in this lab:
#
#   datastore_id = "local"   pve03 has NO LVM thin pool — it was installed as plain
#                            Debian on ext4, so local-lvm is inactive there. A guest
#                            declared for pve03 with local-lvm fails at migration with
#                            "storage does not support CT rootdirs", AFTER copying the
#                            disk. (PET-334)
#   bridge       = vmbr0     pve02 and pve03 both use vmbr0 for the LAN. pve01 used
#                            vmbr1, and on pve02 vmbr1 is the VXLAN bridge — a
#                            different thing whose far end died with pve01.
#   target_node  = "pve03"   The platform node. Changing this later does NOT migrate a
#                            container: on the bpg provider both target_node and
#                            datastore_id force REPLACEMENT.
#
# TF owns existence, hardware and network only. The binary, the systemd unit and the
# SSH key it uses to reach the media hosts are Ansible's, via
# playbooks/configure-media-dash.yml — same split as every other app host here.

module "media_dash" {
  source = "../../modules/proxmox-lxc"

  vm_id        = 237
  hostname     = "media-dash-237"
  ipv4_address = "192.168.50.237/24"

  # Small on purpose. mtrace holds no library, caches nothing and serves one operator:
  # every answer is a live read joined in memory, and the whole triage table across 73
  # seerr requests builds in 0.41 s. If this ever needs more than 512 MB, something has
  # started caching and that is the bug.
  cores            = 1
  memory_dedicated = 512
  disk_size        = 4

  datastore_id = "local"
  target_node  = "pve03"

  # ⚠ PIN THE TEMPLATE TO ONE pve03 ACTUALLY HAS. Templates live on each node's own
  # `local`, which is a directory store and is not shared, so this must name a file
  # present on target_node. The module default is 13.1-2 and pve03 carries only
  # 13.6-1, so taking the default fails the create with "volume … does not exist" —
  # on the apply-on-merge runner, after the merge. runner.tf pins the same value for
  # the same reason; it is the only other greenfield container on this node.
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  ssh_public_key   = var.ssh_public_key
  description      = "mtrace — read-only media stack control surface (PET-355). Managed by Terraform; app by configure-media-dash.yml."
}

output "media_dash_id" {
  description = "VMID of the media-dash container."
  value       = module.media_dash.vm_id
}
