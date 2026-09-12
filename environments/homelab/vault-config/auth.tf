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
# NOTE (sibling exposure, separate issue): media-ci below binds only its main-push sub
# now (PET-163), so the exposure this note described is down to nothing here. colatro-ci
# carried the same shape and is simply gone — removed with the rest of Co-latro in
# PET-366. Kept as a marker: if a future role binds `pull_request` on this backend, the
# SAME org-scoped runner (PET-79) serves it, and that is the risk to weigh.
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


# palworld-panel-cd role → palworld-panel-cd policy. APPLY-on-merge only: the panel repo's
# deploy.yml runs configure-palworld-panel.yml against LXC 234 from the runner on push to main.
# Bound to ONLY the panel repo's main-push sub (the deploy workflow is push-to-main; no PR job
# mints a token). Gets ONLY the ansible SSH key (to reach 234) + the panel's own service secret
# (REST admin password + the restricted start-hook key). Mirrors openfaas-ci. (PET-266)
resource "vault_jwt_auth_backend_role" "palworld_panel_cd" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "palworld-panel-cd"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    sub = "repo:${var.palworld_panel_repo}:ref:refs/heads/main"
  }
  token_policies = [vault_policy.palworld_panel_cd.name]
  token_ttl      = 900
}

# resume-builder-cd role → resume-builder-cd policy (Resume Builder P1). APPLY-on-merge
# only: the app repo's deploy.yml copies build/ + installs the systemd unit on resume-242
# from the runner on push to main. Bound to ONLY the repo's main-push sub. Gets ONLY the
# ansible SSH key (to reach resume-242) + the app's own service secret. Mirrors
# palworld-panel-cd. Apply BEFORE the CD workflow lands or the first run 403s.
resource "vault_jwt_auth_backend_role" "resume_builder_cd" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "resume-builder-cd"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  # Bound on `repository` + `ref` rather than on `sub`, unlike palworld-panel-cd above.
  #
  # GitHub does not emit one stable `sub` format across repos. The panel's repo produces the
  # classic `repo:OWNER/NAME:ref:refs/heads/main`, but this (newer) repo produces an
  # ID-QUALIFIED subject — `repo:PeteDio-Labs@<org-id>/petedio-resume-builder@<repo-id>:ref:…`
  # — so a literal sub binding can never match and the first CD run fails with
  # `claim "sub" does not match any associated bound claim values`. Confirmed via
  # /repos/{owner}/{repo}/actions/oidc/customization/sub, which differs between the two repos.
  #
  # `repository` and `ref` are plain claims with no such prefix games, and together they are
  # exactly as tight as the sub binding was: this repo, pushes to main only (a PR run carries
  # ref=refs/pull/N/merge and is still excluded). Prefer this form for new CD roles.
  bound_claims = {
    repository = var.resume_builder_repo
    ref        = "refs/heads/main"
  }
  token_policies = [vault_policy.resume_builder_cd.name]
  token_ttl      = 900
}

# water-fast-cd role → water-fast-cd policy. The petedio-water-fast repo's CD role: its
# deploy.yml builds the frontend then runs petedio-iac's configure-water-fast.yml against
# waterfast-243 on push to main. Gets ONLY the ansible SSH key (to reach 243) + the app's
# own service secret. Apply BEFORE the CD workflow lands or the first run 403s.
#
# Bound on `repository` + `ref`, NOT on `sub` — see the resume-builder-cd note above. This
# repo was created in 2026 and so emits the ID-QUALIFIED subject
# (`repo:PeteDio-Labs@<org-id>/petedio-water-fast@<repo-id>:ref:...`), which no literal sub
# binding can match. repository + ref is exactly as tight: this repo, pushes to main only
# (a PR run carries ref=refs/pull/N/merge and is excluded).
# media-dash-cd → the petedio-media-control repo's deploy.yml (PET-355).
#
# ⚠ Bound on `repository` + `ref`, NOT on `sub`. petedio-media-control was created in
# 2026-09 and so emits the ID-QUALIFIED subject
# (`repo:PeteDio-Labs@<org-id>/petedio-media-control@<repo-id>:ref:...`), which no literal
# sub binding can match — the failure mode PET-360 spent a day on, where every mint failed
# and the workflow still reported green. repository + ref is exactly as tight: this repo,
# pushes to main only (a PR run carries ref=refs/pull/N/merge and is excluded).
# pete-bot-cd role -> pete-bot-cd policy (PET-375). The pete-bot repo's deploy.yml
# builds the standalone binary and runs configure-pete-bot.yml against media-dash-237.
# Main-push only: a PR run carries ref=refs/pull/N/merge and is excluded.
resource "vault_jwt_auth_backend_role" "pete_bot_cd" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "pete-bot-cd"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository = var.pete_bot_repo
    ref        = "refs/heads/main"
  }
  token_policies = [vault_policy.pete_bot_cd.name]
  token_ttl      = 900
}

resource "vault_jwt_auth_backend_role" "media_dash_cd" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "media-dash-cd"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository = var.media_control_repo
    ref        = "refs/heads/main"
  }
  token_policies = [vault_policy.media_dash_cd.name]
  token_ttl      = 900
}

resource "vault_jwt_auth_backend_role" "water_fast_cd" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "water-fast-cd"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  bound_claims = {
    repository = var.water_fast_repo
    ref        = "refs/heads/main"
  }
  token_policies = [vault_policy.water_fast_cd.name]
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

# plane-ci role → plane-ci policy. Replaces the GitHub↔Linear auto-advance that was
# uninstalled 2026-08-13; Plane's own GitHub integration is a paid feature and is not
# in the self-hosted Community Edition, so CI moves work-item state itself.
#
# TWO SUBJECTS, and both are needed:
#   * ...:pull_request        → plane-sync.yml (pull_request_target: open/ready/merge)
#   * ...:ref:refs/heads/main → plane-reconcile.yml (nightly schedule runs on main)
#
# Binding the pull_request subject is the thing PET-104 forbade for ci-read. It is
# acceptable HERE, and only here, because vault_policy.plane_ci reads exactly one
# secret whose worst case is a wrong issue status. Read that policy's comment before
# touching this role.
resource "vault_jwt_auth_backend_role" "plane_ci" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "plane-ci"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  # BOTH SUBJECT FORMS PER REPO — see the variable's comment and infra_reconcile's.
  # GitHub is migrating repos to immutable, id-based subjects; a role bound only to
  # the name form silently stops matching the moment a repo migrates, and plane-sync
  # reports green while moving nothing. Emitting both is direction-agnostic.
  bound_claims = {
    sub = join(",", flatten([
      for name, id in var.plane_repos : [
        "repo:PeteDio-Labs/${name}:ref:refs/heads/main",
        "repo:PeteDio-Labs/${name}:pull_request",
        "repo:PeteDio-Labs@${var.github_org_id}/${name}@${id}:ref:refs/heads/main",
        "repo:PeteDio-Labs@${var.github_org_id}/${name}@${id}:pull_request",
      ]
    ]))
  }
  token_policies = [vault_policy.plane_ci.name]
  token_ttl      = 300
}

# infra-reconcile role → infra-reconcile policy (PET-294). The nightly job in
# petedio-vault diffs `pct list` against the vault's own host notes and files drift
# as Plane work items.
#
# MAIN-PUSH ONLY, and that is the whole security argument. It holds a Proxmox
# credential, so it must never be mintable from a `pull_request` subject the way
# plane-ci is — see the policy comment and PET-104. One repo, one subject: the
# vault is the register being verified, so its own CI is what verifies it.
resource "vault_jwt_auth_backend_role" "infra_reconcile" {
  backend           = vault_jwt_auth_backend.github.path
  role_name         = "infra-reconcile"
  role_type         = "jwt"
  user_claim        = "actor"
  bound_audiences   = [var.github_oidc_audience]
  bound_claims_type = "string"
  # ⚠ BOTH SUBJECT FORMS, and that is not belt-and-braces.
  #
  # GitHub is migrating repositories to IMMUTABLE, ID-BASED OIDC subjects. A
  # migrated repo stops sending
  #     repo:PeteDio-Labs/petedio-vault:ref:refs/heads/main
  # and starts sending
  #     repo:PeteDio-Labs@268380060/petedio-vault@1312503638:ref:refs/heads/main
  # so a role bound only to the name form can never match again. Read the live
  # prefix with:
  #     gh api /repos/PeteDio-Labs/<repo>/actions/oidc/customization/sub
  #
  # petedio-vault has already migrated. That is why infra-reconcile could not mint
  # a token — and because the job only WARNED on failure, it reported success
  # nightly while checking nothing (PET-317). Binding both forms means a role
  # keeps working across the migration in either direction, with no wildcards:
  # a glob here would loosen the one control that stops another repo minting a
  # Proxmox credential.
  bound_claims = {
    sub = join(",", [
      "repo:PeteDio-Labs/petedio-vault:ref:refs/heads/main",
      "repo:PeteDio-Labs@${var.github_org_id}/petedio-vault@${var.github_repo_id_vault}:ref:refs/heads/main",
    ])
  }
  token_policies = [vault_policy.infra_reconcile.name]
  token_ttl      = 300
}

