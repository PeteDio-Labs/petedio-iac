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

# Co-latro app repos allowed to exchange an Actions OIDC token via the colatro-ci
# JWT role (auth.tf). The app CI (publish-on-merge) + the manual deploy workflow run
# from these repos; each needs Nexus push + MinIO-write (publish) and the LXC SSH key
# (deploy). Kept separate from petedio-iac so app CI never gets the iac creds.
variable "colatro_repos" {
  description = "owner/name of each Co-latro repo bound to the colatro-ci JWT role."
  type        = list(string)
  default = [
    "PeteDio-Labs/co-latro-backend",
    "PeteDio-Labs/co-latro-frontend",
  ]
}

# co-latro-admin repo, bound to its own colatro-admin-ci JWT role (auth.tf, PET-99). The
# admin deploy workflow (Workflow B) runs from this repo and needs the admin-deploy creds
# (admin DB URL + seam token + faasd gateway password + Nexus push + LXC SSH). Kept separate
# from colatro_repos so the app repos never get the admin DB / gateway creds and vice-versa.
variable "colatro_admin_repo" {
  description = "owner/name of the co-latro-admin repo bound to the colatro-admin-ci JWT role."
  type        = string
  default     = "PeteDio-Labs/co-latro-admin"
}
