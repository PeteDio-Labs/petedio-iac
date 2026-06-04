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
# CLAIM BINDING (PET-29 — tightened from repository-only): we bind the OIDC `sub`
# to EXACTLY the two events CI legitimately runs from, so no other branch/tag/
# workflow/environment in this repo (and no other repo) can mint a CI token:
#   - push to main → sub = "repo:<repo>:ref:refs/heads/main"   (apply-on-merge)
#   - pull_request → sub = "repo:<repo>:pull_request"          (plan-on-PR)
# Both terraform jobs (plan + apply) need the backend/provider creds, so BOTH
# subs must be allowed — binding only main would break plan-on-PR.
#
# bound_claims_type = "string" → EXACT match (not glob): these two subs are fixed
# strings with no wildcard. A single claim value may carry multiple comma-separated
# allowed values with OR semantics ("a,b" matches a OR b) — per the hashicorp/vault
# provider docs — so we list both subs in one comma-joined string.
#
# NOTE (follow-up risk, out of scope): this is a PUBLIC repo on a self-hosted
# runner. Fork pull_requests on self-hosted runners are a known exposure
# (untrusted code on a runner that can reach Vault) — track separately.
resource "vault_jwt_auth_backend_role" "github_actions" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "github-actions"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    sub = "repo:${var.github_repo}:ref:refs/heads/main,repo:${var.github_repo}:pull_request"
  }
  token_policies = [vault_policy.ci_read.name]
  token_ttl      = 900
}

# colatro-ci role → colatro-ci policy. Same JWT backend, separate role so the Co-latro
# app repos get ONLY the colatro-ci policy (Nexus + MinIO-write + LXC SSH), never the
# iac ci-read creds. Binds main + pull_request subs for BOTH app repos — built from
# var.colatro_repos and comma-joined into one string (bound_claims_type=string, OR
# semantics), matching the github-actions role's two-sub pattern. Bind main + PR so a
# future PR-time job (e.g. a build check) can also mint a token; publish/deploy gate
# on the workflow's own `if: push to main` / workflow_dispatch.
resource "vault_jwt_auth_backend_role" "colatro_ci" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "colatro-ci"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    sub = join(",", flatten([
      for r in var.colatro_repos : [
        "repo:${r}:ref:refs/heads/main",
        "repo:${r}:pull_request",
      ]
    ]))
  }
  token_policies = [vault_policy.colatro_ci.name]
  token_ttl      = 900
}
