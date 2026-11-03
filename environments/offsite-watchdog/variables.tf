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

variable "budget_alert_emails" {
  description = "Email addresses that receive budget and anomaly alerts. The repository ignores *.tfvars, so pass this on the command line."
  type        = list(string)

  validation {
    condition     = length(var.budget_alert_emails) > 0
    error_message = "Set at least one address: a budget with no subscriber alerts nobody."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly gross-spend limit for petedio-credit-burn."
  type        = number
  default     = 40
}

variable "cumulative_budget_usd" {
  description = "Limit for petedio-credit-cumulative across the credit period."
  type        = number
  default     = 140
}

variable "anomaly_threshold_usd" {
  description = "Minimum total impact of an anomaly, in USD, before the daily digest includes it."
  type        = number
  default     = 5
}

variable "credit_period_start" {
  description = "Start of the cumulative budget, as YYYY-MM-DD_HH:MM in UTC."
  type        = string
  default     = "2026-11-01_00:00"
}

variable "credit_expires" {
  description = "Date the AWS credit ends (YYYY-MM-DD). Ends the cumulative budget and fills the expires tag. PET-723 reminds to act before 2027-04-06."
  type        = string
  default     = "2027-04-20"
}
