# deploy-aws-apply: what aws-apply.yml may read (PET-941 follow-up).
#
# The workflow plans and applies one AWS root, environments/dashboard or environments/portfolio
# (account 847547470418). It needs the
# MinIO key for the Terraform state and nothing else from Vault: the AWS side uses a short-lived
# role from GitHub OIDC, so no AWS key is stored here.
#
# BINDING. The role names the repository, main, workflow_dispatch and that one workflow file, as
# the other deploy-* roles do. Vault cannot tell the plan job from the apply job. The apply job
# gets its AWS write role only after Pedro approves the `lab-write` environment, because the AWS
# role trusts that environment and no other.
resource "vault_policy" "deploy_aws_apply" {
  name = "deploy-aws-apply"

  policy = <<-EOT
    path "kv/data/iac/minio" {
      capabilities = ["read"]
    }
  EOT
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
  }
  token_policies = [vault_policy.deploy_aws_apply.name]
  token_ttl      = 2700
}
