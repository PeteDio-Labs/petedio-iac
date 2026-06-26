# Inputs for the reusable postgres-db module — the RDS-equivalent "create a
# database + its owning login role + grants" building block. The provider
# connection (host/admin creds) is configured by the root module; this module
# only declares the logical database objects.

variable "db_name" {
  description = "Name of the database to create (e.g. the per-app DB)."
  type        = string
  default     = "poker"
}

variable "owner_role" {
  description = "Login role that owns the database (the app connects as this role)."
  type        = string
  default     = "poker"
}

variable "owner_password" {
  description = <<-EOT
    Write-only password for the owning login role. Sourced from an EPHEMERAL Vault
    read / TF_VAR in CI — never hardcoded. Declared `ephemeral = true` (TF 1.11+) so
    the value can flow from an ephemeral resource into postgresql_role.password_wo
    without landing in plan or state (PET-190 / PET-107). Because it is ephemeral it
    MUST be paired with owner_password_version, which is what actually triggers a
    re-apply of the password (an ephemeral value is invisible to the diff).
  EOT
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "owner_password_version" {
  description = <<-EOT
    Version trigger for owner_password (password_wo_version). The role password is
    only (re)written when this integer changes — bump it to rotate a Vault-side
    password through to Postgres, since the ephemeral owner_password itself never
    shows in the diff. Defaults to 1.
  EOT
  type        = number
  default     = 1
}
