# Cloudflare edge references (PET-34). Terraform does NOT create the tunnel or the
# zone — both already exist (the tunnel is token-managed by the cloudflared
# daemon). We only READ them as data sources so later work (DNS records / tunnel
# ingress / public hostnames) can reference stable IDs.
#
# All four values live in Vault KV v2 at kv/iac/cloudflare:
#   api_token  -> the scoped Cloudflare API token the provider authenticates with
#   account_id -> Cloudflare account ID (both data sources are account-scoped)
#   zone_id    -> the pdlab.dev zone ID
#   tunnel_id  -> the existing cloudflared tunnel UUID
# (Distinct from kv/services/cloudflare/tunnel_token — the daemon runtime token.)
#
# UNLIKE the gated poker_db read, this read is NOT gated: Cloudflare is always
# "ready", so plan/refresh always reads it. kv/iac/cloudflare MUST be seeded and
# the ci-read/terraform Vault policies MUST grant read on kv/data/iac/cloudflare
# before plan is clean (the terraform policy already covers kv/data/iac/*; ci-read
# gets an explicit path in vault-config/policies.tf). `terraform validate` never
# reads data sources, so validate stays green with no Vault.
#
# SECRETS-IN-STATE (PET-107): the api_token (the only secret of the four keys; the
# IDs are non-secret) persists in plaintext state. Same fix path as the DB reads —
# ephemeral vault_kv_secret_v2 on vault provider v5. See docs/secrets-in-state.md.
data "vault_kv_secret_v2" "cloudflare" {
  mount = "kv"
  name  = "iac/cloudflare"
}

# Resolve each value TF_VAR-first / Vault-fallback. Only api_token has a matching
# variable (it configures the provider, evaluated before data reads); the IDs are
# read straight from Vault. try() keeps validate / no-Vault from hard-failing.
locals {
  cloudflare_api_token = (
    var.cloudflare_api_token != null
    ? var.cloudflare_api_token
    : try(data.vault_kv_secret_v2.cloudflare.data["api_token"], null)
  )
  cloudflare_account_id = try(data.vault_kv_secret_v2.cloudflare.data["account_id"], null)
  cloudflare_zone_id    = try(data.vault_kv_secret_v2.cloudflare.data["zone_id"], null)
  cloudflare_tunnel_id  = try(data.vault_kv_secret_v2.cloudflare.data["tunnel_id"], null)
}

# Existing pdlab.dev zone. cloudflare provider v5: the singular cloudflare_zone
# data source looks up by zone_id (there is NO top-level `name` argument in v5 —
# name is exported read-only; name-based lookup moved to the plural
# cloudflare_zones + filter). We hold the zone_id in Vault, so feed it directly.
data "cloudflare_zone" "pdlab" {
  zone_id = local.cloudflare_zone_id
}

# Existing cloudflared tunnel. v5 singular data source is identified by
# account_id + tunnel_id (the deterministic pair). We do NOT create it — it's
# token-managed by the daemon on the cloudflare-tunnel host.
data "cloudflare_zero_trust_tunnel_cloudflared" "main" {
  account_id = local.cloudflare_account_id
  tunnel_id  = local.cloudflare_tunnel_id
}

# Prove the data sources resolved (also handy for follow-up ingress work).
output "cloudflare_zone_name" {
  description = "Resolved pdlab.dev zone name (proves the zone data source read)."
  value       = data.cloudflare_zone.pdlab.name
}

output "cloudflare_tunnel_name" {
  description = "Resolved cloudflared tunnel name (proves the tunnel data source read)."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared.main.name
}
