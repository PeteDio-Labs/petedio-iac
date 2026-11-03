# CloudFront only accepts ACM certificates from us-east-1, so the module takes a second
# aws provider for it: `providers = { aws = aws, aws.us_east_1 = aws.us_east_1 }`.
terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.0"
      configuration_aliases = [aws.us_east_1]
    }
  }
}
