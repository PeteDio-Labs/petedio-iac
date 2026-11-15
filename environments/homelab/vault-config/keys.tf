# keys: the two Vault roles .github/workflows/keys.yml mints to list, create, rotate and revoke the
# agents' Cloudflare Access service tokens (design https://claude.ai/artifact/6A23RZ9uT4X74qWX5sHBuy).
#
# WHAT EACH MAY DO.
#   keys-list  read and list KV metadata under kv/callers/edge: agent names, versions, owner,
#              token id and expiry. Never a value. Minted with no approval.
#   keys-sync  keys-list, plus write kv/data/callers/edge/* (the one-header value), write and
#              delete its metadata (revocation destroys the entry), and read
#              kv/services/keys-cloudflare, a Cloudflare token that can edit Access service tokens
#              only. Minted only after Pedro approves the lab-write environment.
# Neither can read any other kv/data path, so a bug in keys.py cannot touch a service's secrets.
#
# ⚠ THE FIRST APPLY OF THIS FILE IS PEDRO'S. The gated vault-config-apply path writes only
# deploy-*, plane-ci and secrets-register names, and scripts/vault-config-guard.py protects
# keys_* addresses, so these roles change only through scripts/apply-vault-config.sh.
resource "vault_policy" "keys_list" {
  name = "keys-list"

  policy = <<-EOT
    path "kv/metadata/callers/edge" {
      capabilities = ["list"]
    }
    path "kv/metadata/callers/edge/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_policy" "keys_sync" {
  name = "keys-sync"

  policy = <<-EOT
    path "kv/metadata/callers/edge" {
      capabilities = ["list"]
    }
    path "kv/metadata/callers/edge/*" {
      capabilities = ["create", "update", "read", "list", "delete"]
    }
    path "kv/data/callers/edge/*" {
      capabilities = ["create", "update"]
    }
    path "kv/data/services/keys-cloudflare" {
      capabilities = ["read"]
    }
  EOT
}

# Bound to the repository, main, workflow_dispatch and the workflow file, as lab-action-read is,
# so a push, a schedule, a pull request or another workflow on main mints nothing.
resource "vault_jwt_auth_backend_role" "keys_list" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "keys-list"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository   = var.github_repo
    ref          = "refs/heads/main"
    event_name   = "workflow_dispatch"
    workflow_ref = "${var.github_repo}/.github/workflows/keys.yml@refs/heads/main"
  }
  token_policies = [vault_policy.keys_list.name]
  token_ttl      = 600
  token_max_ttl  = 600
}

# The environment claim makes Pedro's tap a Vault requirement, not only a GitHub one.
resource "vault_jwt_auth_backend_role" "keys_sync" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "keys-sync"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository   = var.github_repo
    ref          = "refs/heads/main"
    event_name   = "workflow_dispatch"
    environment  = "lab-write"
    workflow_ref = "${var.github_repo}/.github/workflows/keys.yml@refs/heads/main"
  }
  token_policies = [vault_policy.keys_sync.name]
  token_ttl      = 600
  token_max_ttl  = 600
}
