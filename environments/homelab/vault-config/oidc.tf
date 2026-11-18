# Authentik sign-in for Vault's web page and CLI (PET-946).
#
# Pedro signs in to vault.pdlab.dev through Authentik and gets a token that can only list and read
# the metadata under kv/callers/edge: the `keys-list` policy (keys.tf), which holds no secret value.
# The root token stays the break-glass login. This role never grants root, and it never reads a
# kv/data path. Widen the policy in keys.tf, in its own PR, if the page needs more.
#
# This file mounts the method and declares the role. It holds no client secret, so none reaches
# state: scripts/seed-vault-oidc.sh writes auth/oidc/config (discovery URL, client id and secret)
# from the hand-created Authentik "vault" application.
#
# ⚠ THE FIRST APPLY OF THIS FILE IS PEDRO'S. The gated vault-config-apply path writes only
# deploy-*, plane-ci and secrets-register names, so this applies through
# scripts/apply-vault-config.sh on the Mac.
resource "vault_auth_backend" "oidc" {
  type = "oidc"
  path = "oidc"

  tune {
    default_lease_ttl = "1h"
    max_lease_ttl     = "4h"
  }
}

# One role, bound to Pedro's verified Authentik email. A second person needs a second role.
resource "vault_jwt_auth_backend_role" "pedro_oidc" {
  backend   = vault_auth_backend.oidc.path
  role_name = "pedro"
  role_type = "oidc"

  user_claim   = "email"
  bound_claims = { email = "pedelgadillo@gmail.com" }
  oidc_scopes  = ["openid", "email", "profile"]

  allowed_redirect_uris = [
    "https://vault.pdlab.dev/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]

  token_policies = [vault_policy.keys_list.name]
  token_ttl      = 3600
  token_max_ttl  = 14400
}
