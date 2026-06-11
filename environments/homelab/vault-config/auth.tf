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

# agent-loop role → agent-loop policy. The loop host (LXC 242) runs a Vault Agent that
# auto-auths with this AppRole and keeps a renewed token in ~agent/.vault-token, so the
# read-only Proxmox helper self-serves with no per-session login. Unlike the ansible/
# terraform-local roles (short-lived per-run logins), this token is continuously renewed
# by the Agent; the secret_id is non-expiring (default) so the Agent can re-auth when
# token_max_ttl is reached. PET-141.
resource "vault_approle_auth_backend_role" "agent_loop" {
  backend        = vault_auth_backend.approle.path
  role_name      = "agent-loop"
  token_policies = [vault_policy.agent_loop.name]
  token_ttl      = 3600
  token_max_ttl  = 14400
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

# media-ci role → media-ci policy. Same JWT backend, separate role so petedio-
# media-iac CI gets ONLY the media-ci policy (minio/proxmox/lxc-ssh + services/
# media), never the broader iac ci-read scope. Binds main + pull_request subs for
# the media repo — same two-sub exact-match pattern as github-actions
# (plan-on-PR + apply-on-merge both need the backend/provider creds).
resource "vault_jwt_auth_backend_role" "media_ci" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "media-ci"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    sub = "repo:${var.media_repo}:ref:refs/heads/main,repo:${var.media_repo}:pull_request"
  }
  token_policies = [vault_policy.media_ci.name]
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

# openfaas-ci role → openfaas-ci policy. APPLY-on-merge only: ansible-openfaas.yml runs the
# host-config play against LXC 241 from the runner on push to main. Bound to ONLY the
# main-push sub (NOT pull_request — the PR job is a no-secrets syntax-check), so this token
# can't be minted from a PR / fork. Gets only the ansible SSH key + Nexus pull creds.
resource "vault_jwt_auth_backend_role" "openfaas_ci" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "openfaas-ci"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    sub = "repo:${var.github_repo}:ref:refs/heads/main"
  }
  token_policies = [vault_policy.openfaas_ci.name]
  token_ttl      = 900
}
