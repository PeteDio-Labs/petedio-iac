variable "aws_profile" {
  description = "AWS CLI profile for the Dream It Ship It account (847547470418). A profile, not env keys, because the S3 backend reads AWS_ACCESS_KEY_ID for MinIO."
  type        = string
}

variable "aws_region" {
  description = "Region for the API, table and user pool. CloudFront's certificate uses us-east-1 regardless."
  type        = string
  default     = "us-east-2"
}

variable "name" {
  description = "Prefix for resource names."
  type        = string
  default     = "petedio-dash"
}

variable "zone_name" {
  description = "Subdomain delegated from the Cloudflare zone to Route 53. Cloudflare keeps pdlab.dev itself."
  type        = string
  default     = "failover.pdlab.dev"
}

variable "hostname" {
  description = "Name the dashboard answers on, inside zone_name."
  type        = string
  default     = "dash.failover.pdlab.dev"
}

variable "attach_domain" {
  description = <<-EOT
    Create the certificate, the alias and the Route 53 failover records. Leave false for the first
    apply: it creates the zone and prints its name servers, and you verify on the cloudfront.net URL.
    Set true only after the NS delegation for zone_name exists in Cloudflare, because the apply
    then waits for the certificate to validate through that delegation.
  EOT
  type        = bool
  default     = false
}

variable "lab_fallback_target" {
  description = <<-EOT
    DNS name of the on-prem fallback, for the SECONDARY failover record. Null creates no secondary
    record and no lab health check. The design question this waits on is in README.md,
    "On-prem fallback: where TLS ends".
  EOT
  type        = string
  default     = null
}

variable "operator_email" {
  description = "Email of the one Cognito user. Cognito mails the temporary password to it. Supply it in a gitignored tfvars file."
  type        = string
  default     = null
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the roles and users this root creates, when the apply user must attach one (see environments/offsite-watchdog/README.md)."
  type        = string
  default     = null
}

variable "throttle_rate" {
  description = "Steady API requests a second, a cost and abuse cap."
  type        = number
  default     = 10
}

variable "throttle_burst" {
  description = "Burst API requests, a cost and abuse cap."
  type        = number
  default     = 20
}

variable "credit_expires" {
  description = "Date the AWS credit ends, for the expires tag (docs/runbooks and aws/remaining-credits-runbook.md)."
  type        = string
  default     = "2027-04-20"
}
