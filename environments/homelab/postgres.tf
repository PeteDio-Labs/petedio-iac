# postgres-rds (LXC 231) — the RDS-equivalent Postgres host for Co-latro.
# VMID 231 = apps block (.231), VMID = last IP octet. Second consumer of the
# reusable modules/proxmox-lxc module.
#
# TWO-PHASE APPLY (gated on var.postgres_ready — see variables.tf):
#   PHASE 1  (postgres_ready = false):
#     `terraform apply` creates ONLY the 231 LXC. modules/postgres-db has
#     count = 0, so no DB objects are planned and the postgresql provider is
#     never contacted (it's configured but unused — that does not open a
#     connection). This was correct while Postgres wasn't installed yet.
#   --- between phases ---
#     Run ansible/playbooks/configure-postgres.yml against 231: install
#     Postgres, set listen_addresses='*' + pg_hba for 192.168.50.0/24, create
#     the admin role the provider uses. Add TF_VAR_postgres_admin_password (and
#     TF_VAR_poker_db_password) to CI from Vault (PET-6).
#   PHASE 2  (postgres_ready = true — CURRENT default, PET-32):
#     Postgres is LIVE on 231; the `poker` db/owner role/ALL-grant were created
#     MANUALLY (verified). count flips to 1 so TF now manages those objects.
#     CRITICAL: they are NOT in state yet — `terraform import` them BEFORE any
#     apply (else cyrilgdn errors "already exists" / proposes recreating the live
#     db). See docs/runbooks/postgres-import.md.
#
# As with poker-api (230), TF owns existence + hardware + network only; Docker
# is not needed here, but the nesting/keyctl container features still come from
# Ansible (Proxmox's root@pam check rejects API tokens — see docs/GOTCHAS.md).

module "postgres_host" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 231
  hostname         = "postgres-rds-231"
  ipv4_address     = "192.168.50.231/24"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  cores            = 2
  memory_dedicated = 2048
  disk_size        = 20
  description      = "Co-latro Postgres RDS-equivalent host. Managed by Terraform."
}

# Vault-sourced DB secrets (PET-29; consumed by PET-32). KV v2 entry at
# kv/data/poker/db holds { DATABASE_URL, admin_password, poker_password } — the
# exact keys PET-27 seeds (see docs/runbooks/vault-bootstrap.md).
#
# SECRETS-IN-STATE FIX (PET-107 / PET-190): this is now an EPHEMERAL read (vault
# provider v5). An ephemeral resource is never persisted to plan or state, so the
# whole kv/poker/db payload (DATABASE_URL, admin_password, poker_password) stops
# landing in plaintext state on the HTTP MinIO backend. The `.data` output is the
# same string map the v4 data source exposed, so the downstream access pattern is
# unchanged — only the keyword (data -> ephemeral) and the lifecycle differ.
#
# GATED on var.postgres_ready (same gate as the DB module + postgresql provider):
# ephemeral resources are opened at PLAN and APPLY, so an ungated read would hit
# live Vault during a phase-1 plan and fail (no Vault env, secret not seeded until
# PET-27). With count=0 in phase 1 the read never happens. (`terraform validate`
# never opens ephemeral resources, so validate is green regardless.)
ephemeral "vault_kv_secret_v2" "poker_db" {
  count = var.postgres_ready ? 1 : 0
  mount = "kv"
  name  = "poker/db"
}

# Resolve the DB secrets with a TF_VAR-first, Vault-fallback precedence so BOTH
# phases work from one config. NB: poker_db_password / postgres_admin_password now
# reference an EPHEMERAL resource, so these locals are themselves ephemeral and may
# only be consumed in ephemeral-valid contexts:
#   - postgres_admin_password -> the postgresql provider's `password` (provider
#     config is always an ephemeral-valid context — re-evaluated each operation,
#     never stored);
#   - poker_db_password -> module.poker_db owner_password (ephemeral=true) ->
#     postgresql_role.password_wo (a write-only argument).
# Neither may flow into a normal resource arg or an output (Terraform errors at
# validate if it does — a useful guard).
#   PHASE 1 (postgres_ready=false): ephemeral resource absent → both resolve to null
#     (the var defaults). Nothing is required, nothing reads Vault. These locals
#     ARE evaluated in phase-1 (the postgresql provider references the admin one),
#     so the expression MUST tolerate everything being null — hence NOT coalesce(),
#     which errors on all-null. An explicit TF_VAR_* (break-glass) still wins.
#   PHASE 2 (postgres_ready=true): no TF_VAR set → fall through to the Vault value.
locals {
  poker_db_password = (
    var.poker_db_password != null
    ? var.poker_db_password
    : try(ephemeral.vault_kv_secret_v2.poker_db[0].data["poker_password"], null)
  )
  postgres_admin_password = (
    var.postgres_admin_password != null
    ? var.postgres_admin_password
    : try(ephemeral.vault_kv_secret_v2.poker_db[0].data["admin_password"], null)
  )
}

# Gated logical layer: the database + owner role + grants. count = 0 until
# var.postgres_ready flips to true (phase 2), keeping phase-1 applies host-only.
# owner_password is now write-only (password_wo); owner_password_version gates when
# a rotated Vault password is re-applied (the ephemeral value is diff-invisible).
module "poker_db" {
  source = "../../modules/postgres-db"
  count  = var.postgres_ready ? 1 : 0

  db_name                = "poker"
  owner_role             = "poker"
  owner_password         = local.poker_db_password
  owner_password_version = var.poker_db_password_version
}

output "postgres_host_id" {
  description = "VMID of the postgres-rds container."
  value       = module.postgres_host.vm_id
}
