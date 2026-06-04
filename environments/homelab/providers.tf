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
  host = "192.168.50.231"
  port = 5432
  # local.postgres_admin_password (postgres.tf): Vault-first, TF_VAR fallback.
  # Phase 1 it resolves to null and the provider is never contacted (gated).
  username        = var.postgres_admin_user
  password        = local.postgres_admin_password
  sslmode         = "disable"
  superuser       = false
  connect_timeout = 15
}

# Vault provider (PET-29) — source app/DB secrets at apply time instead of static
# CI secrets. Configured ENTIRELY from env so nothing is committed: in CI,
# VAULT_ADDR + VAULT_CACERT come from the workflow `env:` block and VAULT_TOKEN
# from the "Vault — mint creds via OIDC" step (vault-action `exportToken: true`);
# locally the operator exports the same three.
#
# PHASE-1 SAFETY: an empty provider block does NOT open a connection, and
# `terraform validate` never contacts providers — so phase-1 validate works with
# no live Vault. The only Vault read (vault_kv_secret_v2.poker_db, postgres.tf)
# is gated on var.postgres_ready, so phase-1 PLAN never touches Vault either.
#
# skip_child_token: by default the provider mints a short-lived CHILD token from
# VAULT_TOKEN, which needs the token-create capability. In CI the token is the
# OIDC-minted `ci-read` token (read/list only, no token create) → child-token
# creation 403s. Skip it so the provider uses the token directly to read kv/poker/db.
provider "vault" {
  skip_child_token = true
}

# Cloudflare provider (PET-34) — reads the EXISTING Zero Trust tunnel + pdlab.dev
# zone as data sources (cloudflare.tf); creates nothing. api_token resolves
# Vault-first (local.cloudflare_api_token) with a TF_VAR_cloudflare_api_token
# break-glass fallback — the same precedence as local.postgres_admin_password.
#
# The scoped Cloudflare API token lives at kv/iac/cloudflare (distinct from the
# cloudflared *daemon* token at kv/services/cloudflare/tunnel_token that Ansible
# consumes — a different credential). An unset token leaves the provider
# effectively unconfigured; `terraform validate` never contacts it. The
# data-source reads DO require Vault live + kv/iac/cloudflare seeded + the
# ci-read policy granted that path.
provider "cloudflare" {
  api_token = local.cloudflare_api_token
}
