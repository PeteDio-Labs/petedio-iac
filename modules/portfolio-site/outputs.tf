output "bucket" {
  description = "Bucket name, for the deploy workflow's BUCKET variable."
  value       = aws_s3_bucket.site.id
}

output "distribution_id" {
  description = "Distribution ID, for the deploy workflow's DISTRIBUTION_ID variable."
  value       = aws_cloudfront_distribution.site.id
}

output "cloudfront_domain" {
  description = "Default URL to verify the site on before any DNS change."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "deploy_role_arn" {
  description = "Role ARN, for the deploy workflow's AWS_ROLE_ARN variable. Null when deploy_auth is \"user\"."
  value       = one(aws_iam_role.deploy[*].arn)
}

output "deploy_user_name" {
  description = "Deploy IAM user, for scripts/portfolio-deploy-key.sh. Null when deploy_auth is \"oidc\"."
  value       = one(aws_iam_user.deploy[*].name)
}

output "acm_validation_records" {
  description = "DNS records to create in Cloudflare (DNS only, not proxied) to validate the certificate."
  value = [
    for o in aws_acm_certificate.site.domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ]
}
