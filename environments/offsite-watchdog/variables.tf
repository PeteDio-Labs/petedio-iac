variable "aws_region" {
  description = "Region for the watchdog. us-east-2 is the region of the Dream It Ship It account."
  type        = string
  default     = "us-east-2"
}

variable "permissions_boundary_arn" {
  description = "ARN of the petedio-watchdog-boundary IAM policy Pedro creates (README). Required: the apply user may create the function role only with this boundary."
  type        = string
}

variable "heartbeat_max_age_seconds" {
  description = "A heartbeat older than this reads as the lab being down. The lab sends every 2 minutes."
  type        = number
  default     = 900
}

variable "check_interval_minutes" {
  description = "How often the checker runs."
  type        = number
  default     = 5
}

variable "public_checks" {
  description = <<-EOT
    Public endpoints the checker probes from outside. Each: name, url, ok (accepted HTTP
    codes), optional min_cert_days (alert when the certificate has fewer days left).
    Empty until PET-710 supplies the names: Access-fronted names need a service token, so
    they are out of phase 1.
  EOT
  type = list(object({
    name          = string
    url           = string
    ok            = optional(list(number), [200])
    min_cert_days = optional(number, 0)
  }))
  default = []
}
