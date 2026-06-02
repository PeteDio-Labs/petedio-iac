provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # self-signed cert on the homelab Proxmox UI

  ssh {
    agent    = true
    username = "root"
  }
}

# Postgres "RDS" — points at the LXC 231 host (modules/proxmox-lxc, see
# postgres.tf). Connects as the non-super admin role Ansible provisions
# (configure-postgres.yml). sslmode=disable: LAN-only host on 192.168.50.0/24,
# no TLS yet (matches the homelab Proxmox/MinIO posture). superuser=false so the
# provider doesn't assume rolsuper and skips superuser-only probes.
#
# Phase 1 (var.postgres_ready=false): no postgres-db resources exist, so this
# provider is never contacted even though it's configured. Phase 2 flips the
# flag once Postgres is actually running + reachable here.
provider "postgresql" {
  host            = "192.168.50.231"
  port            = 5432
  username        = var.postgres_admin_user
  password        = var.postgres_admin_password
  sslmode         = "disable"
  superuser       = false
  connect_timeout = 15
}
