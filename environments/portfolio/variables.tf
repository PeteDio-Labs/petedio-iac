variable "aws_profile" {
  description = "AWS CLI profile for the Dream It Ship It account (847547470418). A profile, not env keys, because the S3 backend reads AWS_ACCESS_KEY_ID for MinIO."
  type        = string
}

variable "attach_domain" {
  description = "Attach pdlab.dev to the distribution. Applied true on 2026-11-06 (PET-816). Setting it false removes the alias and the certificate validation."
  type        = bool
  default     = true
}

variable "budget_limit_usd" {
  description = "Monthly cost budget for the portfolio in USD. 0 creates none."
  type        = number
  default     = 0
}

variable "budget_emails" {
  description = "Budget notification addresses. Pass with -var at apply time; never commit one."
  type        = list(string)
  default     = []
}
