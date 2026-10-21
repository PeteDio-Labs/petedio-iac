# secrets-register: the nightly job that joins secrets/register.yml with Vault KV metadata
# (PET-685, finding S5 and S6 of the 2026-10-19 secrets check).
#
# WHAT IT MAY READ. KV metadata for every path (names, versions and timestamps, never a value)
# and one secret, kv/services/secrets-register, which holds a copy of the token that opens
# pete-bot's /v1/notify. The job DMs Pedro with it when the register check fails.
# scripts/seed-secrets-register.sh places the copy. Vault cannot scope a read to one field of
# kv/services/pete-bot, which also holds the Discord token and the merge desk's App key.
#
# WHY METADATA IS A WIDE GRANT HERE. `kv/metadata/*` read lets a token list every path name
# and read its version history and custom_metadata. That is the whole point of the job, and it
# exposes no value. A token minted here cannot read kv/data/* outside its one path.
resource "vault_policy" "secrets_register" {
  name = "secrets-register"

  policy = <<-EOT
    path "kv/metadata/*" {
      capabilities = ["read", "list"]
    }

    path "kv/data/services/secrets-register" {
      capabilities = ["read"]
    }
  EOT
}

# secrets-register role → secrets-register policy. Bound to the repository, main, the two events
# that start the job, and the workflow file, as claude-247-deploy is. A `sub` alone names a
# branch, so any workflow on main could mint it (docs/GOTCHAS.md, PET-675). A comma-separated
# string is OR for one claim (the provider takes strings only).
resource "vault_jwt_auth_backend_role" "secrets_register" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "secrets-register"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository   = var.github_repo
    ref          = "refs/heads/main"
    event_name   = "schedule,workflow_dispatch"
    workflow_ref = "${var.github_repo}/.github/workflows/secrets-register.yml@refs/heads/main"
  }
  token_policies = [vault_policy.secrets_register.name]
  token_ttl      = 600
}
