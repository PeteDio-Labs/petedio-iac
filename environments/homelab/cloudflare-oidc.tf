# Cloudflare Access ← Authentik OIDC identity provider (PET-38 close-out).
#
# This registers Authentik (auth.pdlab.dev, SSO LXC 119) as an OIDC login method for
# Cloudflare Access, so any `access = true` route with
#   allowed_idps = [cloudflare_zero_trust_access_identity_provider.authentik.id]
# sends the user straight to the Authentik login page instead of Cloudflare's One-Time PIN.
# admin.pdlab.dev (PET-87) is the first consumer; fleet/vault are one-line follow-ups.
#
# PLANE SPLIT (see docs/runbooks/fleet-activity-view.md §"Swap login to Authentik OIDC"):
# the Authentik-side OAuth2/OpenID *provider + application* is created BY HAND in the
# Authentik dashboard (the automation never mutates the SSO box) with slug `cloudflare-access`
# and redirect URI https://petedillo-labs.cloudflareaccess.com/cdn-cgi/access/callback. That
# hand-created app mints the client_id / client_secret consumed below.
#
# ORDER: the Authentik app + `scripts/reseed-authentik-oidc-vault.sh` (seeds kv/iac/authentik)
# must run BEFORE this applies, or the data source below reads an absent path and the apply
# fails. ci-read is granted kv/data/iac/authentik (vault-config/policies.tf) so apply-on-merge
# can resolve it.

data "vault_kv_secret_v2" "authentik" {
  mount = "kv"
  name  = "iac/authentik"
}

resource "cloudflare_zero_trust_access_identity_provider" "authentik" {
  account_id = local.cloudflare_account_id
  name       = "authentik"
  type       = "oidc"

  config = {
    client_id     = data.vault_kv_secret_v2.authentik.data["oidc_client_id"]
    client_secret = data.vault_kv_secret_v2.authentik.data["oidc_client_secret"]
    auth_url      = "https://auth.pdlab.dev/application/o/authorize/"
    token_url     = "https://auth.pdlab.dev/application/o/token/"
    certs_url     = "https://auth.pdlab.dev/application/o/cloudflare-access/jwks/"
    scopes        = ["openid", "email", "profile"]
    pkce_enabled  = true
  }
}
