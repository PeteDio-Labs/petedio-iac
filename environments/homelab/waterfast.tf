# waterfast-243 (LXC 243) — host for the family water-fasting tracker
# (petedio-water-fast, fast.pdlab.dev). Public at fast.pdlab.dev behind Cloudflare Access +
# Authentik, with data in the `waterfast` database on postgres-rds-231.
#
# VMID 243 = compute block (.243), VMID = last IP octet — the next free number after 242
# (resume). 244 is tailscale. Verified free against `pct list` on both nodes (the live
# inventory in the vault, ground-truthed 2026-07-25, lists 241/242/244 and no 243).
#
# Ubuntu LTS (24.04 noble) to match resume-242 — same runtime shape (a native Bun systemd
# service on :8080 fronted by the tunnel), so the os_type override is the same one
# agent-loop.tf carries.
#
# Sized small on purpose: the app is one Bun process serving a static bundle and a handful
# of JSON routes, and Postgres lives on 231 rather than here. No Docker, so no
# nesting/keyctl and nothing Ansible has to set over node SSH.

module "waterfast" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 243
  hostname         = "waterfast-243"
  ipv4_address     = "192.168.50.243/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 1
  memory_dedicated = 1024
  disk_size        = 16
  template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  os_type          = "ubuntu"
  description      = "Water fast tracker host (fast.pdlab.dev) — Bun/Preact, Postgres on 231. Managed by Terraform."
}

output "waterfast_id" {
  description = "VMID of the water-fast container."
  value       = module.waterfast.vm_id
}

# The `waterfast` database on postgres-rds-231 is declared in databases.tf with every other
# Postgres database, and adopted there by `import` blocks — it was created by hand alongside
# the first deploy, exactly as `poker` originally was.
#
# The old var.waterfast_db_ready gate is gone. It existed to keep an ephemeral read of a
# not-yet-seeded kv/services/water-fast from failing the plan that gated the merge; the path
# is seeded now (scripts/reseed-water-fast-vault.sh), so var.postgres_ready — the same gate
# every other database uses — is sufficient and the special case has earned its removal.
#
# PREREQUISITE for apply-on-merge: ci-read must be able to read kv/data/services/water-fast.
# That grant lives in the vault-config root, which is operator-applied with the root token
# and deliberately never runs in CI, so it does NOT land with a normal merge —
# scripts/apply-vault-config.sh has to have run first or the apply fails on a permission
# denied it can't diagnose for itself.
