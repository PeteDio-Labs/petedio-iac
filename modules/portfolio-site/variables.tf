variable "name" {
  description = "Prefix for resource names."
  type        = string
  default     = "petedio-portfolio"
}

variable "domain_name" {
  description = "Apex domain the site answers on. DNS lives in Cloudflare, so the module only outputs the records to create."
  type        = string
  default     = "pdlab.dev"
}

variable "attach_domain" {
  description = <<-EOT
    Attach domain_name to the distribution. Leave false for the first apply so you can verify
    on the cloudfront.net URL. Set true only after the ACM validation record exists in
    Cloudflare: the apply then waits for the certificate to validate.
  EOT
  type        = bool
  default     = false
}

variable "github_repo" {
  description = "GitHub repository (owner/name) allowed to assume the deploy role."
  type        = string
  default     = "PeteDio-Labs/pdlabs-portfolio"
}

variable "github_branch" {
  description = "Branch whose workflow runs may assume the deploy role."
  type        = string
  default     = "main"
}

variable "deploy_auth" {
  description = <<-EOT
    How the deploy workflow authenticates. "oidc" creates a GitHub OIDC deploy role (no key).
    "user" creates a deploy-only IAM user, for accounts whose service control policy denies
    the OIDC provider; the access key is made by scripts/portfolio-deploy-key.sh, not Terraform.
  EOT
  type        = string
  default     = "oidc"

  validation {
    condition     = contains(["oidc", "user"], var.deploy_auth)
    error_message = "deploy_auth must be \"oidc\" or \"user\"."
  }
}

variable "create_github_oidc_provider" {
  description = "Create the account's GitHub OIDC provider (deploy_auth oidc only). Set false if the account already has one: an account holds one per URL."
  type        = bool
  default     = true
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 serves North America and Europe, the cheapest."
  type        = string
  default     = "PriceClass_100"
}

variable "tags" {
  description = "Tags added to every taggable resource."
  type        = map(string)
  default     = {}
}
