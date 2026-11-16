output "bucket" {
  description = "SPA bucket, for the deploy workflow's BUCKET variable."
  value       = aws_s3_bucket.site.id
}

output "distribution_id" {
  description = "Distribution ID, for the deploy workflow's DISTRIBUTION_ID variable."
  value       = aws_cloudfront_distribution.site.id
}

output "cloudfront_domain" {
  description = "Default URL to verify the dashboard on before any DNS change."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "function_name" {
  description = "Lambda name, for the deploy workflow's update-function-code call."
  value       = aws_lambda_function.api.function_name
}

output "api_endpoint" {
  description = "execute-api URL. pete-bot and the watchdogs sign requests to /api/ingest/* against this host directly."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "table_name" {
  value = aws_dynamodb_table.dash.name
}

output "user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "user_pool_client_id" {
  description = "Public SPA client id. Not a secret."
  value       = aws_cognito_user_pool_client.spa.id
}

output "cognito_domain" {
  description = "Hosted UI host."
  value       = "${aws_cognito_user_pool_domain.this.domain}.auth.${var.aws_region}.amazoncognito.com"
}

output "name_servers" {
  description = "Create one NS record per value for zone_name in Cloudflare (environments/homelab) before attach_domain = true."
  value       = aws_route53_zone.failover.name_servers
}

output "ingest_user_name" {
  description = "IAM user for pete-bot's status pushes. A script that Pedro runs makes its access key."
  value       = aws_iam_user.ingest.name
}

output "deploy_user_name" {
  description = "IAM user for the deploy workflow. A script that Pedro runs makes its access key."
  value       = aws_iam_user.deploy.name
}
