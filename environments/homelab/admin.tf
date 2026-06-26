# admin DB — the co-latro-admin service's own logical DB on postgres-rds-231 (PET-88).
# Mirrors module.poker_db: same two-phase gate (var.postgres_ready) + the postgresql
# provider the root module already configures. The co-latro-admin service connects as
# the `admin` role.
#
# Secret: kv/admin/db { owner_password } — seed BEFORE apply (scripts/reseed-admin-db-vault.sh)
# and grant ci-read/terraform read on kv/data/admin/* (vault-config/policies.tf) so CI can
# resolve it at plan time. Unlike poker (created manually then imported), the `admin` db is
# NEW — TF CREATES it, so no import is needed.
#
# SECRETS-IN-STATE FIX (PET-107 / PET-190): like poker_db, this is now an EPHEMERAL
# read so owner_password never lands in plaintext state, and it feeds password_wo on
# the role. Same gate + null-tolerant resolution as poker_db. docs/secrets-in-state.md.

ephemeral "vault_kv_secret_v2" "admin_db" {
  count = var.postgres_ready ? 1 : 0
  mount = "kv"
  name  = "admin/db"
}

# admin_db_password is ephemeral (references the ephemeral read above), so it may
# only feed module.admin_db owner_password (ephemeral=true) -> password_wo.
locals {
  admin_db_password = (
    var.admin_db_password != null
    ? var.admin_db_password
    : try(ephemeral.vault_kv_secret_v2.admin_db[0].data["owner_password"], null)
  )
}

module "admin_db" {
  source = "../../modules/postgres-db"
  count  = var.postgres_ready ? 1 : 0

  db_name                = "admin"
  owner_role             = "admin"
  owner_password         = local.admin_db_password
  owner_password_version = var.admin_db_password_version
}
