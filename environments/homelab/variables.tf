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

variable "manage_resource_pool" {
  description = <<-EOT
    Gate for pool.tf (PET-160, after the PET-159 poison-pill incident). FALSE until the IaC
    token (petedio@pam!iac) holds Pool.Allocate on /pool/homelab — granted out-of-band per the
    PET-159 runbook. While false the pool + memberships are a no-op (count 0 / empty for_each),
    so a missing pool privilege can't fail apply-on-merge for the whole workspace. Set the repo
    var MANAGE_RESOURCE_POOL=true after the grant; CI's preflight then verifies Pool.Allocate at
    PR time before the change can merge.
  EOT
  type        = bool
  default     = false
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

variable "poker_db_password_version" {
  description = <<-EOT
    password_wo_version for the `poker` owner role (PET-190). The role password is
    write-only/ephemeral and so diff-invisible — bump this integer to push a rotated
    kv/poker/db value through to Postgres on the next apply. Leave unchanged otherwise.
  EOT
  type        = number
  default     = 1
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

variable "admin_db_password_version" {
  description = <<-EOT
    password_wo_version for the `admin` owner role (PET-190). Same role as
    poker_db_password_version: bump to push a rotated kv/admin/db value through to
    Postgres on the next apply (the write-only password is otherwise diff-invisible).
  EOT
  type        = number
  default     = 1
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

# Non-secret Cloudflare IDs (PET-190). Previously read from the kv/iac/cloudflare
# data source alongside api_token — but a vault_kv_secret_v2 *data source* persists
# its WHOLE payload (incl. api_token) in state, so we could not keep it just for the
# IDs without re-leaking the token. The token now comes from an EPHEMERAL read
# (cloudflare.tf), and these IDs — which are NOT secret and must feed non-ephemeral
# contexts (the cloudflare_zone data-source arg + outputs) — move to plain TF_VARs.
# Seed them in CI from kv/iac/cloudflare (TF_VAR_cloudflare_{account,zone,tunnel}_id)
# the same way TF_VAR_cloudflare_api_token is seeded. They default to null so
# validate degrades cleanly with no Vault/CI env.
variable "cloudflare_account_id" {
  description = "Cloudflare account ID (non-secret). From kv/iac/cloudflare via TF_VAR in CI."
  type        = string
  default     = null
}

variable "cloudflare_zone_id" {
  description = "pdlab.dev zone ID (non-secret). From kv/iac/cloudflare via TF_VAR in CI."
  type        = string
  default     = null
}

variable "cloudflare_tunnel_id" {
  description = "Existing cloudflared tunnel UUID (non-secret). From kv/iac/cloudflare via TF_VAR in CI."
  type        = string
  default     = null
}

variable "cloudflare_palworld_tunnel_id" {
  description = <<-EOT
    UUID of the SECOND cloudflared tunnel, whose connector runs ON the game host
    (palworld-mc) so palworld.pdlab.dev can reach the panel over 127.0.0.1 — the whole
    point of PET-266's loopback bind. Non-secret; the runtime token is separate and lives
    at kv/services/palworld-panel (field tunnel_token).

    Like the main tunnel, Terraform does NOT create this — it is token-managed by the
    daemon, and having TF create it would persist the token in state (the leak PET-107/190
    fixed). Operator creates it in Cloudflare, then scripts/seed-palworld-tunnel-vault.sh
    stores the token AND writes this UUID to kv/iac/cloudflare, where terraform.yml reads
    it into this TF_VAR.

    DELIBERATELY REQUIRED — no default. A null default let the module count to 0 while the
    `moved` blocks below still pointed at it, which reads as "source gone" and DESTROYS the
    live Access application, its policy, and the CNAME on a public hostname. Failing the
    plan with "No value for required variable" is the correct outcome for a missing ID.
  EOT
  type        = string
}
