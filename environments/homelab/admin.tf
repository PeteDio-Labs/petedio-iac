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
# SECRETS-IN-STATE (PET-107): like poker_db, this data source lands owner_password in
# plaintext state. Same fix path (ephemeral read, vault provider v5). docs/secrets-in-state.md.

data "vault_kv_secret_v2" "admin_db" {
  count = var.postgres_ready ? 1 : 0
  mount = "kv"
  name  = "admin/db"
}

locals {
  admin_db_password = (
    var.admin_db_password != null
    ? var.admin_db_password
    : try(data.vault_kv_secret_v2.admin_db[0].data["owner_password"], null)
  )
}

module "admin_db" {
  source = "../../modules/postgres-db"
  count  = var.postgres_ready ? 1 : 0

  db_name        = "admin"
  owner_role     = "admin"
  owner_password = local.admin_db_password
}
