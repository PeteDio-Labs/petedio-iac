# GitHub repo allowed to exchange an Actions OIDC token for a Vault token via the
# JWT auth role (auth.tf). Matched against the `repository` claim in the OIDC JWT.
variable "github_repo" {
  description = "owner/name of the GitHub repo bound to the github-actions JWT role."
  type        = string
  default     = "PeteDio-Labs/petedio-iac"
}

# GitHub repo for the media stack IaC (petedio-media-iac). Bound to its own
# `media-ci` JWT role so media CI gets ONLY the read creds it needs (minio +
# proxmox + lxc-ssh + services/media) and never the broader iac ci-read scope.
variable "media_repo" {
  description = "owner/name of the petedio-media-iac repo bound to the media-ci JWT role."
  type        = string
  default     = "PeteDio-Labs/petedio-media-iac"
}

# OIDC audience the JWT role accepts. MUST match the `jwtGithubAudience` that
# hashicorp/vault-action sends from the workflow — if they disagree, Vault rejects
# the login with an audience-mismatch error.
variable "github_oidc_audience" {
  description = "Expected `aud` claim on the GitHub Actions OIDC token (must equal vault-action's jwtGithubAudience)."
  type        = string
  default     = "https://github.com/PeteDio-Labs"
}

# Every repo whose CI moves Plane work-item state (plane-sync.yml). Bound to the
# plane-ci JWT role, whose policy reads exactly ONE secret — see policies.tf. Adding a
# repo here is what lets its PRs mint that token; it grants nothing else.
# ⚠ A MAP, NOT A LIST, AND THE ID IS THE POINT (PET-360).
#
# This was a list of "owner/name" strings, and plane-ci built one subject per entry
# from the name. GitHub is migrating repos to IMMUTABLE, ID-BASED OIDC subjects, so a
# migrated repo stops sending the name form entirely and its mint is refused — while
# plane-sync, which is advisory by design, reports GREEN and moves nothing.
#
# petedio-vault had been in that state since at least 2026-09-01: every plane-sync run
# failed the mint, every run was green, and no work item in that repo ever advanced.
#
# So the id is carried here and BOTH subject forms are always emitted. That is
# migration-direction-agnostic: it keeps working whether a repo has migrated, has not
# yet, or migrates tomorrow, with no wildcards. A glob would loosen the one control
# that stops an unrelated repo minting this token.
#
# To add a repo: `gh api repos/PeteDio-Labs/<name> --jq .id`. IDs are immutable, which
# is the whole reason GitHub is moving to them, so they do not rot.
variable "plane_repos" {
  description = "Repo name → numeric GitHub id, for every repo bound to the plane-ci JWT role. Both OIDC subject forms are emitted for each."
  type        = map(string)
  default = {
    "petedio-iac"            = "1257211720"
    "petedio-media-iac"      = "1259824681"
    "co-latro-backend"       = "1257111349"
    "co-latro-frontend"      = "1257111463"
    "co-latro-admin"         = "1263295666"
    "petedio-resume-builder" = "1308151391" # migrated to the id form
    "petedio-palworld-panel" = "1296187459"
    "petedio-water-fast"     = "1313093957" # migrated to the id form
    "petedio-vault"          = "1312503638" # migrated to the id form
    "petedio-workspace"      = "1257293543" # added in PET-360; had no binding at all (PET-290)
    "petedio-media-control"  = "1358823831" # migrated to the id form; new in PET-355
  }
}

# GitHub repo for the Palworld control panel (petedio-palworld-panel). Bound to its own
# palworld-panel-cd JWT role (auth.tf) so the panel's deploy-on-merge gets ONLY the ansible
# SSH key + its own service secret, never the broader iac/ansible scope. (PET-266)
variable "palworld_panel_repo" {
  description = "owner/name of the petedio-palworld-panel repo bound to the palworld-panel-cd JWT role."
  type        = string
  default     = "PeteDio-Labs/petedio-palworld-panel"
}

# GitHub repo for the resume builder app (Resume Builder P1). Bound to its own
# resume-builder-cd JWT role (auth.tf) so its deploy-on-merge gets ONLY the ansible SSH
# key + its own service secret, never the broader iac/ansible scope.
variable "resume_builder_repo" {
  description = "owner/name of the petedio-resume-builder repo bound to the resume-builder-cd JWT role."
  type        = string
  default     = "PeteDio-Labs/petedio-resume-builder"
}

variable "water_fast_repo" {
  description = "owner/name of the petedio-water-fast repo bound to the water-fast-cd JWT role."
  type        = string
  default     = "PeteDio-Labs/petedio-water-fast"
}

# GitHub's numeric IDs, used to build the IMMUTABLE OIDC subject form. GitHub is
# migrating repositories from name-based to ID-based subjects, and a migrated repo
# stops sending the name form entirely. Read the current prefix for any repo with:
#   gh api /repos/PeteDio-Labs/<repo>/actions/oidc/customization/sub
# Surveyed 2026-09-06: FOUR have migrated — petedio-vault, petedio-resume-builder,
# petedio-water-fast and petedio-media-control. The rest still send the name form.
# Do not maintain that list as a condition anywhere; emit both forms and stop caring.
variable "github_org_id" {
  description = "Numeric GitHub org ID for PeteDio-Labs, used in immutable OIDC subjects."
  type        = string
  default     = "268380060"
}

variable "github_repo_id_vault" {
  description = "Numeric repo ID for petedio-vault, used in its immutable OIDC subject."
  type        = string
  default     = "1312503638"
}
