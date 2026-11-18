# cf-logs-read role → cf-logs-read policy. .github/workflows/cf-access-logs.yml reads Cloudflare's
# Access authentication logs, so a thread can see why a sign-in ended without asking Pedro to open
# the dashboard. The token it uses is read-only: Account > Access: Audit Logs > Read, and nothing else.
#
# WHAT THE POLICY MAY DO. Read one KV path, kv/data/services/cloudflare-logs, which holds that
# token and the account id. No write, no list, no other path.
#
# ⚠ BOUND TO THE WORKFLOW AND THE EVENT, as keys-list and lab-action-read are: repository, main,
# workflow_dispatch and this one workflow file. A push, a schedule, a pull request or another
# workflow on main mints nothing. A dispatch needs write access to the repo.
#
# ⚠ THE FIRST APPLY OF THIS FILE IS PEDRO'S. The gated vault-config-apply path writes only
# deploy-*, plane-ci and secrets-register names, so run scripts/apply-vault-config.sh on the Mac.
resource "vault_policy" "cf_logs_read" {
  name = "cf-logs-read"

  policy = <<-EOT
    path "kv/data/services/cloudflare-logs" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_jwt_auth_backend_role" "cf_logs_read" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "cf-logs-read"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository   = var.github_repo
    ref          = "refs/heads/main"
    event_name   = "workflow_dispatch"
    workflow_ref = "${var.github_repo}/.github/workflows/cf-access-logs.yml@refs/heads/main"
  }
  token_policies = [vault_policy.cf_logs_read.name]
  token_ttl      = 600
  token_max_ttl  = 600
}
