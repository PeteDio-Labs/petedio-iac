# Reusable Postgres database + owner role — the RDS-equivalent logical layer.
# Mirrors what you'd do with aws_db_instance + a bootstrap role in real RDS:
# the host (instance) is created elsewhere (modules/proxmox-lxc + Ansible);
# this module creates the database, its owning login role, and grants.
#
# The cyrilgdn/postgresql provider connects as a (non-super) admin role that
# Ansible provisions on the host — see environments/homelab/providers.tf.
#
# SECRETS-IN-STATE (PET-107): `password` persists in this resource's state.
# cyrilgdn/postgresql v1.26 (the locked version) offers write-only `password_wo` +
# `password_wo_version` to keep it out of state — but the SAME secret is still in
# state at the vault_kv_secret_v2 data-source layer (postgres.tf/admin.tf), so
# password_wo only pays off bundled with the ephemeral vault read (provider v5).
# Decision + options: docs/secrets-in-state.md.
resource "postgresql_role" "owner" {
  name     = var.owner_role
  login    = true
  password = var.owner_password
}

resource "postgresql_database" "this" {
  name  = var.db_name
  owner = postgresql_role.owner.name
}

resource "postgresql_grant" "owner_all" {
  database    = postgresql_database.this.name
  role        = postgresql_role.owner.name
  object_type = "database"
  privileges  = ["ALL"]
}
