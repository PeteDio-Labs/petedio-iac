# deploy-aws-plan and deploy-aws-apply: what aws-apply.yml may read (PET-941).
#
# The workflow plans and applies one AWS root, environments/dashboard or environments/portfolio
# (account 847547470418). The account's service control policy denies an OIDC provider, so a job
# cannot assume an AWS role. It reads an IAM user's key from Vault instead.
#
# Two roles keep the write keys behind Pedro's tap:
#   deploy-aws-plan   reads the two read-only plan entries: an AWS read-only key and a MinIO service
#                     account that reads one root's state only. Any dispatch of the
#                     workflow on main gets it.
#   deploy-aws-apply  reads the two apply entries: an AWS write key and a MinIO service account that
#                     writes one root's state only. It is also bound to the
#                     `lab-write` environment, so Vault refuses it until Pedro approves the job.
# Neither reads the shared kv/iac/minio key, which can overwrite any root's state. Each is bound to the repository, main, workflow_dispatch and the one workflow file, never to
# `sub` alone.
resource "vault_policy" "deploy_aws_plan" {
  name = "deploy-aws-plan"

  policy = <<-EOT
    path "kv/data/services/aws-ci/dashboard-plan" {
      capabilities = ["read"]
    }
    path "kv/data/services/aws-ci/portfolio-plan" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "deploy_aws_apply" {
  name = "deploy-aws-apply"

  policy = <<-EOT
    path "kv/data/services/aws-ci/dashboard-apply" {
      capabilities = ["read"]
    }
    path "kv/data/services/aws-ci/portfolio-apply" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_jwt_auth_backend_role" "deploy_aws_plan" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "deploy-aws-plan"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository   = var.github_repo
    ref          = "refs/heads/main"
    event_name   = "workflow_dispatch"
    workflow_ref = "${var.github_repo}/.github/workflows/aws-apply.yml@refs/heads/main"
  }
  token_policies = [vault_policy.deploy_aws_plan.name]
  token_ttl      = 2700
}

resource "vault_jwt_auth_backend_role" "deploy_aws_apply" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "deploy-aws-apply"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository   = var.github_repo
    ref          = "refs/heads/main"
    event_name   = "workflow_dispatch"
    workflow_ref = "${var.github_repo}/.github/workflows/aws-apply.yml@refs/heads/main"
    environment  = "lab-write"
  }
  token_policies = [vault_policy.deploy_aws_apply.name]
  token_ttl      = 2700
}
