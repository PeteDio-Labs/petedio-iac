# Lab dashboard, AWS side (primary). S3 + CloudFront serve the SPA, HTTP API + Lambda + DynamoDB
# serve the data, Cognito signs you in without Authentik, and Route 53 holds the failover pair on a
# delegated subdomain. pete-bot on 237 stays the warm Lab fallback.
#
# Apply by hand from the Mac or 247 as a host step, after Pedro says go. Nothing here runs from CI.
# Rollout order and the cost estimate are in README.md.
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias   = "us_east_1" # CloudFront reads ACM certificates only from here
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  tags = {
    project = "petedio-dashboard"
    expires = var.credit_expires
  }
  account_id = data.aws_caller_identity.current.account_id
}
