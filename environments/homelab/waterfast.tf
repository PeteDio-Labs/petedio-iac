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

# ---- the `waterfast` database on postgres-rds-231 ----------------------------------------
#
# Gated on var.waterfast_db_ready (default FALSE) *in addition to* var.postgres_ready, and
# that second gate is load-bearing rather than belt-and-braces:
#
# The ephemeral Vault read below is opened at PLAN as well as apply. If it were ungated it
# would reach for kv/services/water-fast during the very first plan of this PR — before the
# operator has seeded that path — and fail the plan, which is the merge gate for the whole
# workspace. The same trap as the PET-19 incident recorded in .agent/lessons.md, where a
# newly-declared required variable broke a gated apply.
#
# ORDER for the operator:
#   1. merge this PR with waterfast_db_ready = false (plan is a no-op for the DB objects)
#   2. seed Vault:  vault kv put kv/services/water-fast db_password=… \
#                     cf_access_team_domain=… cf_access_aud=…
#   3. set the repo variable WATERFAST_DB_READY=true and re-apply — the DB + owner role
#      are then created by Terraform.
ephemeral "vault_kv_secret_v2" "waterfast" {
  count = var.postgres_ready && var.waterfast_db_ready ? 1 : 0
  mount = "kv"
  name  = "services/water-fast"
}

locals {
  # TF_VAR-first, Vault-fallback — the same precedence poker uses, so a break-glass override
  # works without editing config. Ephemeral, so it may only flow into ephemeral-valid
  # contexts (the module's write-only owner_password); Terraform errors at validate if it
  # ever reaches a normal argument or an output, which is a useful guard.
  waterfast_db_password = (
    var.waterfast_db_password != null
    ? var.waterfast_db_password
    : try(ephemeral.vault_kv_secret_v2.waterfast[0].data["db_password"], null)
  )
}

module "waterfast_db" {
  source = "../../modules/postgres-db"
  count  = var.postgres_ready && var.waterfast_db_ready ? 1 : 0

  db_name                = "waterfast"
  owner_role             = "waterfast"
  owner_password         = local.waterfast_db_password
  owner_password_version = var.waterfast_db_password_version
}
