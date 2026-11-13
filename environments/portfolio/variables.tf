variable "aws_profile" {
  description = "AWS CLI profile for the Dream It Ship It account (847547470418). A profile, not env keys, because the S3 backend reads AWS_ACCESS_KEY_ID for MinIO."
  type        = string
}

variable "attach_domain" {
  description = "Attach pdlab.dev to the distribution. Applied true on 2026-11-06 (PET-816). Setting it false removes the alias and the certificate validation."
  type        = bool
  default     = true
}
