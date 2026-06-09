variable "proxmox_endpoint" {
  description = <<-EOT
    Proxmox API endpoint (https://<node>:8006/). bpg/proxmox reads the PVE
    version from this endpoint and conditionally sends version-gated fields, so
    target the node where the resources actually live (pve01 9.1.x here).
  EOT
  type        = string
  default     = "https://192.168.50.10:8006/"
}

variable "proxmox_api_token" {
  description = "Full token: 'user@realm!tokenid=secret'. Minted via pveum (petedio@pam!petedio)."
  type        = string
  sensitive   = true
}

variable "target_node" {
  description = "Proxmox node where these resources live."
  type        = string
  default     = "pve01"
}

variable "ssh_public_key" {
  description = "SSH public key installed for root inside each LXC (matches the key Ansible logs in with)."
  type        = string
}

variable "postgres_admin_user" {
  description = "Admin/login role the postgresql provider connects as (provisioned by Ansible on the 231 host)."
  type        = string
  default     = "postgres"
}

variable "postgres_admin_password" {
  description = <<-EOT
    Password for postgres_admin_user. Sourced from Vault (PET-6) and passed as
    TF_VAR_postgres_admin_password in CI — never committed. Only consumed once
    var.postgres_ready = true (phase 2); the provider isn't contacted before then.
    Defaults to null so phase-1 plan/apply needs no secret; REQUIRED when
    postgres_ready = true.
  EOT
  type        = string
  sensitive   = true
  default     = null
}

variable "poker_db_password" {
  description = <<-EOT
    Password for the `poker` DB owner role created by modules/postgres-db.
    Sourced from Vault (PET-6) / TF_VAR_poker_db_password in CI — never committed.
    Defaults to null so phase-1 plan/apply needs no secret; REQUIRED when
    postgres_ready = true.
  EOT
  type        = string
  sensitive   = true
  default     = null
}

variable "postgres_ready" {
  description = <<-EOT
    Two-phase gate for the Postgres "RDS".

    PHASE 1 (false, default): a plain `terraform apply` creates ONLY the LXC 231
    host. No postgres-db resources are planned, so the postgresql provider is
    never contacted (Postgres isn't installed/reachable yet — a configured-but-
    unused provider does not connect).

    PHASE 2 (true, current default — PET-32): Postgres is live on 231 and the
    `poker` db/role were created MANUALLY (verified, scram TCP). The default is
    now true so CI's apply-on-merge agrees with reality. The live objects are NOT
    in TF state yet, so they MUST be `terraform import`ed BEFORE any apply runs
    with this flag — otherwise cyrilgdn errors "already exists" or proposes
    recreating the live db. See docs/runbooks/postgres-import.md (import-before-
    apply, lockstep ordering, 0-to-destroy gate).
  EOT
  type        = bool
  default     = true
}

variable "admin_db_password" {
  description = <<-EOT
    Password for the `admin` DB owner role (the co-latro-admin service, PET-88). Sourced from
    Vault (kv/admin/db, field owner_password) and passed as TF_VAR_admin_db_password in CI;
    defaults to null so validate/plan without Vault degrade cleanly (resolver falls back to the
    Vault data-source value, explicit TF_VAR wins). Seed kv/admin/db + grant ci-read read on
    kv/data/admin/* BEFORE the consuming apply (lessons.md no-default-var / cutover ordering).
  EOT
  type        = string
  sensitive   = true
  default     = null
}

variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflare API token the cloudflare provider authenticates with to READ the
    existing Zero Trust tunnel + pdlab.dev zone (cloudflare.tf). Sourced from
    Vault (kv/iac/cloudflare, field api_token) and passed as
    TF_VAR_cloudflare_api_token in CI — never committed. Defaults to null so
    validate/plan without Vault degrade cleanly; the resolver falls back to the
    Vault data-source value and an explicit TF_VAR wins as break-glass. Distinct
    from the cloudflared daemon token at kv/services/cloudflare/tunnel_token
    (consumed by Ansible, not Terraform).
  EOT
  type        = string
  sensitive   = true
  default     = null
}
