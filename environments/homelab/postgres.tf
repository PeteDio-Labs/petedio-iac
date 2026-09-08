# postgres-rds (LXC 231) — the RDS-equivalent Postgres host. Built for Co-latro,
# which is gone (PET-366); it now serves waterfast and plane.
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
#     the admin role the provider uses. Add TF_VAR_postgres_admin_password to CI
#     from Vault (PET-6). (TF_VAR_poker_db_password went with PET-366.)
#   PHASE 2  (postgres_ready = true — CURRENT default, PET-32):
#     Postgres is LIVE on 231. The `poker` db/owner role/ALL-grant that this phase
#     was written to import were DESTROYED in PET-366 with the rest of Co-latro;
#     the databases TF manages here now are `waterfast` and `plane`, both created
#     by TF rather than imported. Kept for the import procedure itself, which still
#     applies to any brownfield database: see docs/runbooks/postgres-import.md.
#
# TF owns existence + hardware + network only here; Docker
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
  description      = "Postgres RDS-equivalent host. Managed by Terraform."
}

# The postgresql PROVIDER's admin credential. KV v2 entry at kv/data/poker/db holds
# { DATABASE_URL, admin_password, poker_password } — the exact keys PET-27 seeds (see
# docs/runbooks/vault-bootstrap.md).
#
# ⚠⚠ DO NOT DELETE kv/poker/db BECAUSE "POKER IS GONE". The name is a trap and it now
# names nothing that exists: the poker database, its owner role and the whole Co-latro
# stack were removed in PET-366, and this path OUTLIVED them on purpose. It holds the
# SERVER-WIDE admin credential the postgresql provider authenticates with, so deleting it
# would leave Terraform unable to manage postgres-231 at all — taking `plane` and
# `waterfast` with it. The `poker_password` field inside it is the part that is now dead.
#
# The path name is historical: this entry predates there being more than one database, so
# the server-wide admin credential ended up under `poker/`. It is read here for
# `admin_password` ONLY — the per-database owner passwords resolve in databases.tf. The two
# reads are deliberately separate: this one is a property of the SERVER and must resolve for
# the provider to connect at all, while those are properties of individual databases.
#
# Moving it to a sensibly-named path is worth doing and is not this change: it means
# reseeding, updating every policy that grants kv/data/poker/*, and a window where the
# provider cannot connect. Filed separately rather than smuggled into a teardown.
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
ephemeral "vault_kv_secret_v2" "postgres_admin" {
  count = var.postgres_ready ? 1 : 0
  mount = "kv"
  name  = "poker/db"
}

# TF_VAR-first, Vault-fallback so BOTH phases work from one config. This local references
# an EPHEMERAL resource, so it is itself ephemeral and may only be consumed in an
# ephemeral-valid context — here, the postgresql provider's `password` (provider config
# always qualifies: re-evaluated each operation, never stored). It may not flow into a
# normal resource argument or an output; Terraform errors at validate if it does, which is
# a useful guard.
#   PHASE 1 (postgres_ready=false): the ephemeral resource is absent → this resolves to
#     null (the var default). Nothing is required, nothing reads Vault. The local IS still
#     evaluated in phase 1 (the provider references it), so the expression MUST tolerate
#     null — hence `try`, not coalesce(), which errors when everything is null.
#   PHASE 2 (postgres_ready=true): no TF_VAR set → fall through to the Vault value.
locals {
  postgres_admin_password = (
    var.postgres_admin_password != null
    ? var.postgres_admin_password
    : try(ephemeral.vault_kv_secret_v2.postgres_admin[0].data["admin_password"], null)
  )
}

# The logical layer — every database, its owner role and grants — lives in databases.tf.

output "postgres_host_id" {
  description = "VMID of the postgres-rds container."
  value       = module.postgres_host.vm_id
}
