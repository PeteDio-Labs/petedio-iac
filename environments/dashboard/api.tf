# Data plane: one DynamoDB table, one Lambda, one HTTP API. The Lambda handler lives in pete-bot
# (dashboard/api/) and ships through the deploy user, so Terraform owns the function's existence
# and permissions and never its code.

resource "aws_dynamodb_table" "dash" {
  name         = "dash"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "expires"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false # every item is a snapshot the lab pushes again within minutes
  }
}

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/${var.name}-api"
  retention_in_days = 14
}

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fn" {
  name                 = "${var.name}-api"
  assume_role_policy   = data.aws_iam_policy_document.assume_lambda.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "fn" {
  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query", "dynamodb:UpdateItem", "dynamodb:BatchGetItem"]
    resources = [aws_dynamodb_table.dash.arn]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.fn.arn}:*"]
  }
}

resource "aws_iam_role_policy" "fn" {
  name   = "${var.name}-api"
  role   = aws_iam_role.fn.id
  policy = data.aws_iam_policy_document.fn.json
}

data "archive_file" "stub" {
  type        = "zip"
  source_file = "${path.module}/stub/handler.mjs"
  output_path = "${path.module}/.build/stub.zip"
}

resource "aws_lambda_function" "api" {
  function_name = "${var.name}-api"
  role          = aws_iam_role.fn.arn
  runtime       = "nodejs22.x"
  architectures = ["arm64"]
  handler       = "handler.handler"
  filename      = data.archive_file.stub.output_path
  timeout       = 10
  memory_size   = 256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.dash.name
    }
  }

  # The deploy user replaces the code. Without this, every plan would offer to put the stub back.
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }

  depends_on = [aws_cloudwatch_log_group.fn, aws_iam_role_policy.fn]
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name}-api"
  protocol_type = "HTTP"
  # No CORS block: the SPA calls /api/* on its own origin through CloudFront.
}

resource "aws_apigatewayv2_integration" "fn" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.this.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.spa.id]
    issuer   = "https://${aws_cognito_user_pool.this.endpoint}"
  }
}

locals {
  # route key => authorization. Ingest is IAM (SigV4) only and is called on the execute-api URL
  # directly, never through CloudFront, because SigV4 signs the Host header.
  routes = {
    "GET /api/health"          = "NONE"
    "GET /api/dashboard"       = "JWT"
    "POST /api/switch"         = "JWT"
    "POST /api/ingest/status"  = "AWS_IAM"
    "POST /api/ingest/section" = "AWS_IAM"
  }
}

resource "aws_apigatewayv2_route" "this" {
  for_each = local.routes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.fn.id}"
  authorization_type = each.value
  authorizer_id      = each.value == "JWT" ? aws_apigatewayv2_authorizer.cognito.id : null
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${var.name}"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate
    throttling_burst_limit = var.throttle_burst
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId = "$context.requestId", routeKey = "$context.routeKey", status = "$context.status",
      ip        = "$context.identity.sourceIp", latency = "$context.responseLatency",
    })
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

# pete-bot and the watchdog Lambdas call the ingest routes with SigV4. Terraform creates the
# principal and its policy and never an access key: a script that Pedro runs makes the key.
data "aws_iam_policy_document" "ingest" {
  statement {
    actions = ["execute-api:Invoke"]
    resources = [
      "${aws_apigatewayv2_api.this.execution_arn}/*/POST/api/ingest/status",
      "${aws_apigatewayv2_api.this.execution_arn}/*/POST/api/ingest/section",
    ]
  }
}

resource "aws_iam_policy" "ingest" {
  name   = "${var.name}-ingest"
  policy = data.aws_iam_policy_document.ingest.json
}

resource "aws_iam_user" "ingest" {
  name                 = "${var.name}-ingest"
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_user_policy_attachment" "ingest" {
  user       = aws_iam_user.ingest.name
  policy_arn = aws_iam_policy.ingest.arn
}

# CI deploy user: writes the SPA, invalidates CloudFront and replaces the Lambda code. The account's
# SCP denies the GitHub OIDC provider (PET-816), so this is a user, like the portfolio's.
data "aws_iam_policy_document" "deploy" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.site.arn]
  }
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
  }
  statement {
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = [aws_cloudfront_distribution.site.arn]
  }
  statement {
    actions   = ["lambda:UpdateFunctionCode", "lambda:GetFunction", "lambda:GetFunctionConfiguration"]
    resources = [aws_lambda_function.api.arn]
  }
}

resource "aws_iam_user" "deploy" {
  name                 = "${var.name}-deploy"
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_user_policy" "deploy" {
  name   = "${var.name}-deploy"
  user   = aws_iam_user.deploy.name
  policy = data.aws_iam_policy_document.deploy.json
}
