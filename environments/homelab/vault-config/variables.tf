# GitHub repo allowed to exchange an Actions OIDC token for a Vault token via the
# JWT auth role (auth.tf). Matched against the `repository` claim in the OIDC JWT.
variable "github_repo" {
  description = "owner/name of the GitHub repo bound to the github-actions JWT role."
  type        = string
  default     = "PeteDio-Labs/petedio-iac"
}

# OIDC audience the JWT role accepts. MUST match the `jwtGithubAudience` that
# hashicorp/vault-action sends from the workflow — if they disagree, Vault rejects
# the login with an audience-mismatch error.
variable "github_oidc_audience" {
  description = "Expected `aud` claim on the GitHub Actions OIDC token (must equal vault-action's jwtGithubAudience)."
  type        = string
  default     = "https://github.com/PeteDio-Labs"
}
