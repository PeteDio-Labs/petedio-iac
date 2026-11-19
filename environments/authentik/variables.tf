variable "aws_profile" {
  description = "AWS CLI profile for account 847547470418. A profile, not env keys, because the S3 backend reads AWS_ACCESS_KEY_ID for MinIO."
  type        = string
}

variable "aws_region" {
  description = "Region for the host, its network and its bucket."
  type        = string
  default     = "us-east-2"
}

variable "name" {
  description = "Prefix for resource names. The CI apply policy and the boundary name resources by this prefix."
  type        = string
  default     = "petedio-authentik"
}

variable "permissions_boundary_arn" {
  description = "Boundary that the host role must carry. scripts/seed-aws-ci.sh creates it, and the CI apply user may create a role only with it attached."
  type        = string
}

variable "instance_type" {
  description = "Authentik's server, worker, Postgres and Redis need about 1.5 GiB. t4g.small has 2 GiB, and the host adds 2 GiB of swap."
  type        = string
  default     = "t4g.small"
}

variable "root_volume_gb" {
  description = "Root disk. It holds Docker images, the database and the media folder."
  type        = number
  default     = 30
}

variable "vpc_cidr" {
  description = "The host's own network. It does not overlap the lab's 192.168.50.0/24 or the mesh's 192.168.86.0/24."
  type        = string
  default     = "10.72.0.0/24"
}

variable "authentik_version" {
  description = <<-EOT
    The Authentik image tag. It must equal authentik_version in ansible/roles/authentik/defaults/main.yml
    while the lab copy exists, because the database moves between the two by pg_dump and pg_restore.
  EOT
  type        = string
  default     = "2024.12.5"

  validation {
    condition     = can(regex("^20[0-9]{2}\\.[0-9]+\\.[0-9]+$", var.authentik_version))
    error_message = "authentik_version is a release tag such as 2024.12.5."
  }
}

variable "accept_restore" {
  description = <<-EOT
    Let the host replace its database with the newest dump under migrate/ in its bucket. True while
    the lab copy serves auth.pdlab.dev. Set it false and apply it, after the final copy is restored
    and before the homelab change that moves auth.pdlab.dev to AWS merges. A late copy from the lab
    then cannot overwrite the live database.
  EOT
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Days the bucket keeps each nightly dump under backups/."
  type        = number
  default     = 14
}

variable "credit_expires" {
  description = "Date the AWS credits end. Tagged on every resource, so a later review finds what the credits paid for."
  type        = string
  default     = "2027-04-20"
}
