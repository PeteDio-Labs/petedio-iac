# Sign-in that does not depend on Authentik, the first failover service. One user, created by an
# administrator, with optional TOTP. The pool is the dashboard's own and federates to nothing.
resource "aws_cognito_user_pool" "this" {
  name                     = var.name
  mfa_configuration        = "OPTIONAL"
  deletion_protection      = "ACTIVE"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 3
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.name}-${local.account_id}"
  user_pool_id = aws_cognito_user_pool.this.id
}

resource "aws_cognito_user_pool_client" "spa" {
  name         = "${var.name}-spa"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret                      = false # a browser cannot keep one
  explicit_auth_flows                  = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors        = "ENABLED"
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = concat(
    ["https://${aws_cloudfront_distribution.site.domain_name}/"],
    var.attach_domain ? ["https://${var.hostname}/"] : [],
  )
  logout_urls = concat(
    ["https://${aws_cloudfront_distribution.site.domain_name}/"],
    var.attach_domain ? ["https://${var.hostname}/"] : [],
  )

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 7
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

# The operator. Cognito emails a temporary password, so no credential passes through Terraform.
resource "aws_cognito_user" "operator" {
  count = var.operator_email == null ? 0 : 1

  user_pool_id = aws_cognito_user_pool.this.id
  username     = var.operator_email

  attributes = {
    email          = var.operator_email
    email_verified = true
  }
}
