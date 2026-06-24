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
# CLAIM BINDING — MAIN-PUSH ONLY (PET-104; was two-sub under PET-29). We bind the
# OIDC `sub` to EXACTLY the one event that legitimately needs homelab creds:
#   - push to main → sub = "repo:<repo>:ref:refs/heads/main"   (apply-on-merge)
# The `pull_request` sub was REMOVED. This is a PUBLIC repo and the apply runner is
# self-hosted inside the homelab, so minting backend/provider creds on a PR run
# (which executes PR-controlled terraform/workflow code) put arbitrary code next to
# live creds. The PR job is now a GitHub-HOSTED, no-Vault fmt/validate
# (.github/workflows/terraform.yml), so nothing on a PR needs — or may mint — a token
# here. Matches the openfaas-ci role's main-only pattern below.
#
# bound_claims_type = "string" → EXACT match (not glob): the sub is a fixed string
# with no wildcard.
#
# NOTE (sibling exposure, separate issues): media-ci and colatro-ci below still bind
# their `pull_request` subs, and the SAME org-scoped runner (PET-79) serves them — same
# risk, same fix needed in petedio-media-iac / co-latro. Not changed here: dropping their
# PR sub without updating those repos' PR workflows would break them (one repo per PR).
resource "vault_jwt_auth_backend_role" "github_actions" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "github-actions"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    sub = "repo:${var.github_repo}:ref:refs/heads/main"
  }
  token_policies = [vault_policy.ci_read.name]
  token_ttl      = 900
}

# media-ci role → media-ci policy. Same JWT backend, separate role so petedio-
# media-iac CI gets ONLY the media-ci policy (minio/proxmox/lxc-ssh + services/
# media), never the broader iac ci-read scope. MAIN-PUSH ONLY (PET-163; was
# two-sub): the pull_request sub was dropped now that media-iac's PR job is a
# GitHub-hosted, no-Vault validate (terraform.yml split) — nothing on a PR needs
# or may mint media-ci. Matches the github-actions role above.
resource "vault_jwt_auth_backend_role" "media_ci" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "media-ci"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    sub = "repo:${var.media_repo}:ref:refs/heads/main"
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

# vault-snapshot role → vault-snapshot policy (PET-109). The raft-snapshot systemd timer
# on .223 (Ansible role vault-snapshot) logs in with this AppRole to take + upload a
# snapshot. Short token TTL — the job runs in seconds and re-auths each run; the secret_id
# is seeded out-of-band on the host (operator, root-only file). See the resilience runbook.
resource "vault_approle_auth_backend_role" "vault_snapshot" {
  backend        = vault_auth_backend.approle.path
  role_name      = "vault-snapshot"
  token_policies = [vault_policy.vault_snapshot.name]
  token_ttl      = 300
  token_max_ttl  = 600
}

# poker-api role → poker-api policy (PET-57). The Vault Agent on LXC 230 auto-auths with
# this AppRole and renews a token used to render the backend env-file (DATABASE_URL) to a
# tmpfs path — replacing the old 0600 plaintext at rest. Like agent-loop, the token is
# continuously renewed by the Agent and the secret_id is seeded out-of-band on the host.
resource "vault_approle_auth_backend_role" "poker_api" {
  backend        = vault_auth_backend.approle.path
  role_name      = "poker-api"
  token_policies = [vault_policy.poker_api.name]
  token_ttl      = 3600
  token_max_ttl  = 14400
}
