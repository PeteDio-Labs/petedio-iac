# Reusable Postgres database + owner role — the RDS-equivalent logical layer.
# Mirrors what you'd do with aws_db_instance + a bootstrap role in real RDS:
# the host (instance) is created elsewhere (modules/proxmox-lxc + Ansible);
# this module creates the database, its owning login role, and grants.
#
# The cyrilgdn/postgresql provider connects as a (non-super) admin role that
# Ansible provisions on the host — see environments/homelab/providers.tf.

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
