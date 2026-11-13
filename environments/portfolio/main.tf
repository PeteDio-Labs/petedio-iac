# Portfolio site hosting (PET-774, PET-816): S3 + CloudFront + a deploy-only IAM user.
# The account's SCP denies the GitHub OIDC provider (PET-816), so deploy_auth is "user".
# Apply by hand from the Mac or 247; nothing here runs from CI. Rollout order is in
# modules/portfolio-site/README.md.
provider "aws" {
  region  = "us-east-2"
  profile = var.aws_profile
}

provider "aws" {
  alias   = "us_east_1" # CloudFront reads ACM certificates only from here
  region  = "us-east-1"
  profile = var.aws_profile
}

module "portfolio" {
  source = "../../modules/portfolio-site"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  github_repo   = "PeteDio-Labs/pdlabs-portfolio"
  deploy_auth   = "user"
  attach_domain = var.attach_domain
  tags          = { project = "petedio-portfolio" }
}

output "bucket" { value = module.portfolio.bucket }
output "distribution_id" { value = module.portfolio.distribution_id }
output "cloudfront_domain" { value = module.portfolio.cloudfront_domain }
output "deploy_user_name" { value = module.portfolio.deploy_user_name }
output "acm_validation_records" { value = module.portfolio.acm_validation_records }
