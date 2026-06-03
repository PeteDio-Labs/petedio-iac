# Auth backends + roles. token_policies reference the vault_policy resources by
# .name so Terraform orders policy creation before the roles that grant them.

# AppRole — machine logins for local Ansible/Terraform runs (role_id + secret_id).
resource "vault_auth_backend" "approle" {
  type = "approle"
}

# Ansible host-config role → ansible policy.
resource "vault_approle_auth_backend_role" "ansible" {
  backend        = vault_auth_backend.approle.path
  role_name      = "ansible"
  token_policies = [vault_policy.ansible.name]
  token_ttl      = 1200
  token_max_ttl  = 3600
}

# Local Terraform role → terraform policy.
resource "vault_approle_auth_backend_role" "terraform_local" {
  backend        = vault_auth_backend.approle.path
  role_name      = "terraform-local"
  token_policies = [vault_policy.terraform.name]
  token_ttl      = 1200
  token_max_ttl  = 3600
}

# JWT auth for GitHub Actions OIDC. Mounted at a non-default path (`jwt-github`)
# so a future second JWT issuer can coexist. type=jwt validates the Actions OIDC
# token against GitHub's discovery URL.
resource "vault_jwt_auth_backend" "github" {
  path               = "jwt-github"
  type               = "jwt"
  oidc_discovery_url = "https://token.actions.githubusercontent.com"
  bound_issuer       = "https://token.actions.githubusercontent.com"
}

# github-actions role → ci-read policy. role_type MUST be "jwt": the provider
# default is "oidc", and bound_audiences is required for jwt-type roles.
#
# For now we bind by `repository` only. When the CI cutover lands (deferred
# PET-29), tighten this with a ref/branch bound_claim (e.g. only refs/heads/main)
# so non-default branches can't mint a CI token.
resource "vault_jwt_auth_backend_role" "github_actions" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "github-actions"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "glob"
  bound_claims = {
    repository = var.github_repo
  }
  token_policies = [vault_policy.ci_read.name]
  token_ttl      = 900
}
