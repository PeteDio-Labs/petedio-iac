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
  description = "Password for the owning login role. Sourced from Vault / TF_VAR in CI — never hardcoded."
  type        = string
  sensitive   = true
}
