# Cloudflare edge references (PET-34). Terraform does NOT create the tunnel or the
# zone — both already exist (the tunnel is token-managed by the cloudflared
# daemon). We only READ them as data sources so later work (DNS records / tunnel
# ingress / public hostnames) can reference stable IDs.
#
# All four values originate in Vault KV v2 at kv/iac/cloudflare:
#   api_token  -> the scoped Cloudflare API token the provider authenticates with
#   account_id -> Cloudflare account ID (both data sources are account-scoped)
#   zone_id    -> the pdlab.dev zone ID
#   tunnel_id  -> the existing cloudflared tunnel UUID
# (Distinct from kv/services/cloudflare/tunnel_token — the daemon runtime token.)
#
# SECRETS-IN-STATE FIX (PET-107 / PET-190): the api_token is the only SECRET of the
# four keys, but the old `data "vault_kv_secret_v2"` persisted its WHOLE payload —
# token included — in plaintext state. A KV v2 read is all-or-nothing (you can't pull
# a single key), so we cannot keep a data source just for the non-secret IDs without
# re-leaking the token. So:
#   - api_token  -> EPHEMERAL read (below), consumed ONLY by the provider config
#     (an ephemeral-valid context). Never persisted to plan/state.
#   - IDs        -> plain TF_VARs (var.cloudflare_{account,zone,tunnel}_id, seeded
#     from kv/iac/cloudflare in CI). They are non-secret and must feed non-ephemeral
#     contexts (the cloudflare_zone data-source arg + the outputs below), where an
#     ephemeral value is NOT allowed.
# Net: nothing from kv/iac/cloudflare lands in state anymore.
#
# The ephemeral read is NOT gated (unlike poker_db): Cloudflare is always "ready",
# so the provider always needs the token. kv/iac/cloudflare MUST be seeded and the
# ci-read/terraform Vault policies MUST grant read on kv/data/iac/cloudflare before a
# plan/apply is clean. `terraform validate` never opens ephemeral resources, so
# validate stays green with no Vault (the try() below also degrades to the TF_VAR).
ephemeral "vault_kv_secret_v2" "cloudflare" {
  mount = "kv"
  name  = "iac/cloudflare"
}

# api_token: TF_VAR-first (break-glass), then the ephemeral Vault value. This local
# is EPHEMERAL (it references the ephemeral read) and so may only feed the provider
# config below. The IDs come straight from their TF_VARs — non-secret, non-ephemeral.
locals {
  cloudflare_api_token = (
    var.cloudflare_api_token != null
    ? var.cloudflare_api_token
    : try(ephemeral.vault_kv_secret_v2.cloudflare.data["api_token"], null)
  )
  cloudflare_account_id = var.cloudflare_account_id
  cloudflare_zone_id    = var.cloudflare_zone_id
  cloudflare_tunnel_id  = var.cloudflare_tunnel_id
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
