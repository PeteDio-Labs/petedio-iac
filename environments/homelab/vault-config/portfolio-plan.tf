# portfolio-plan: what portfolio-plan.yml may read (PET-884). The workflow plans
# environments/portfolio on the homelab runner when a thread dispatches it.
#
# WHAT IT MAY READ. One path, kv/services/aws-portfolio-plan. It holds an AWS key for an IAM user
# with a read-only inline policy and a MinIO service account that reads tfstate/portfolio/* only
# (scripts/seed-aws-portfolio-plan.sh), so a leaked token reads infrastructure and state and
# writes neither. It cannot read the shared kv/iac/minio key, which can overwrite any root's state,
# or the deploy user's key at kv/services/portfolio-deploy.
resource "vault_policy" "portfolio_plan" {
  name = "portfolio-plan"

  policy = <<-EOT
    path "kv/data/services/aws-portfolio-plan" {
      capabilities = ["read"]
    }
  EOT
}

# portfolio-plan role → portfolio-plan policy. Bound to the repository, main, workflow_dispatch
# and the workflow file, as lab-action-read is, so a push, a schedule, a pull request or another
# workflow mints nothing. A dispatch needs write access, so a fork cannot start one.
resource "vault_jwt_auth_backend_role" "portfolio_plan" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "portfolio-plan"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository   = var.github_repo
    ref          = "refs/heads/main"
    event_name   = "workflow_dispatch"
    workflow_ref = "${var.github_repo}/.github/workflows/portfolio-plan.yml@refs/heads/main"
  }
  token_policies = [vault_policy.portfolio_plan.name]
  token_ttl      = 900
}
