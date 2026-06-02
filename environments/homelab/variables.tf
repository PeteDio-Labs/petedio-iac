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
  EOT
  type        = string
  sensitive   = true
}

variable "poker_db_password" {
  description = <<-EOT
    Password for the `poker` DB owner role created by modules/postgres-db.
    Sourced from Vault (PET-6) / TF_VAR_poker_db_password in CI — never committed.
  EOT
  type        = string
  sensitive   = true
}

variable "postgres_ready" {
  description = <<-EOT
    Two-phase gate for the Postgres "RDS".

    PHASE 1 (false, default): a plain `terraform apply` creates ONLY the LXC 231
    host. No postgres-db resources are planned, so the postgresql provider is
    never contacted (Postgres isn't installed/reachable yet — a configured-but-
    unused provider does not connect).

    PHASE 2 (true): after Ansible (configure-postgres.yml) installs Postgres,
    opens listen_addresses/pg_hba, and creates the admin role — and once
    TF_VAR_postgres_admin_password is in CI — flip this to true so the next apply
    creates the `poker` database, owner role, and grants.
  EOT
  type        = bool
  default     = false
}
