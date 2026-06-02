# postgres-rds (LXC 231) — the RDS-equivalent Postgres host for Co-latro.
# VMID 231 = apps block (.231), VMID = last IP octet. Second consumer of the
# reusable modules/proxmox-lxc module.
#
# TWO-PHASE APPLY (gated on var.postgres_ready — see variables.tf):
#   PHASE 1  (postgres_ready = false, the default):
#     `terraform apply` creates ONLY the 231 LXC. modules/postgres-db has
#     count = 0, so no DB objects are planned and the postgresql provider is
#     never contacted (it's configured but unused — that does not open a
#     connection). This is correct because Postgres isn't installed yet.
#   --- between phases ---
#     Run ansible/playbooks/configure-postgres.yml against 231: install
#     Postgres, set listen_addresses='*' + pg_hba for 192.168.50.0/24, create
#     the admin role the provider uses. Add TF_VAR_postgres_admin_password (and
#     TF_VAR_poker_db_password) to CI from Vault (PET-6).
#   PHASE 2  (postgres_ready = true):
#     Flip the flag; the next apply creates the `poker` database, its owner
#     role, and grants via the postgresql provider against the live host.
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

# Gated logical layer: the database + owner role + grants. count = 0 until
# var.postgres_ready flips to true (phase 2), keeping phase-1 applies host-only.
module "poker_db" {
  source = "../../modules/postgres-db"
  count  = var.postgres_ready ? 1 : 0

  db_name        = "poker"
  owner_role     = "poker"
  owner_password = var.poker_db_password
}

output "postgres_host_id" {
  description = "VMID of the postgres-rds container."
  value       = module.postgres_host.vm_id
}
