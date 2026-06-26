# Reusable Postgres database + owner role — the RDS-equivalent logical layer.
# Mirrors what you'd do with aws_db_instance + a bootstrap role in real RDS:
# the host (instance) is created elsewhere (modules/proxmox-lxc + Ansible);
# this module creates the database, its owning login role, and grants.
#
# The cyrilgdn/postgresql provider connects as a (non-super) admin role that
# Ansible provisions on the host — see environments/homelab/providers.tf.
#
# SECRETS-IN-STATE (PET-107 / PET-190): the role password is now WRITE-ONLY.
# cyrilgdn/postgresql v1.26+ (locked) offers `password_wo` + `password_wo_version`,
# which keep the password out of this resource's state. password_wo is fed an
# EPHEMERAL value (var.owner_password, ephemeral=true) sourced from the ephemeral
# vault_kv_secret_v2 reads in postgres.tf/admin.tf — so the secret no longer lands
# in state at EITHER the role layer or the (formerly data-source) Vault-read layer.
#
# password_wo and password are MUTUALLY EXCLUSIVE — `password` is removed. Because a
# write-only value is invisible to the diff, password_wo_version (var.owner_password_version)
# is what gates re-application: bump it to push a rotated Vault password through.
# Decision + options: docs/secrets-in-state.md.
resource "postgresql_role" "owner" {
  name                = var.owner_role
  login               = true
  password_wo         = var.owner_password
  password_wo_version = var.owner_password_version
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
