# Off-site watchdog (PET-722). The lab sends a heartbeat to the Lambda function URL; a
# scheduled run of the same function posts to Discord when the heartbeat stops, and probes
# the public endpoints from outside the house. One Lambda, one table, no VPC, no servers.
#
# The IAM user that applies this module is scoped by NAME to petedio-watchdog-* (the policy
# is in README.md). Nothing here runs from CI: apply it by hand from 247.

locals {
  name          = "petedio-watchdog"
  param_token   = "/petedio-watchdog/discord_bot_token"
  param_channel = "/petedio-watchdog/discord_dm_channel_id"
  param_beat    = "/petedio-watchdog/heartbeat_secret"
  tags          = { project = "petedio-watchdog" }
}

# The watchdog's secrets live in Vault. The aws provider authenticates from this read, and the
# two SSM parameters take the other fields as write-only values, so none of them reaches state.
ephemeral "vault_kv_secret_v2" "watchdog" {
  mount = "kv"
  name  = "services/aws-watchdog"
}

provider "vault" {
  skip_child_token = true
}

provider "aws" {
  region     = var.aws_region
  access_key = ephemeral.vault_kv_secret_v2.watchdog.data["aws_access_key_id"]
  secret_key = ephemeral.vault_kv_secret_v2.watchdog.data["aws_secret_access_key"]

  default_tags {
    tags = local.tags
  }
}

resource "aws_ssm_parameter" "discord_bot_token" {
  name             = local.param_token
  type             = "SecureString"
  value_wo         = ephemeral.vault_kv_secret_v2.watchdog.data["discord_bot_token"]
  value_wo_version = 1 # bump to push a rotated value from Vault
}

resource "aws_ssm_parameter" "discord_dm_channel_id" {
  name             = local.param_channel
  type             = "SecureString"
  value_wo         = ephemeral.vault_kv_secret_v2.watchdog.data["discord_dm_channel_id"]
  value_wo_version = 1 # bump to push a rotated value from Vault
}

resource "aws_ssm_parameter" "heartbeat_secret" {
  name             = local.param_beat
  type             = "SecureString"
  value_wo         = ephemeral.vault_kv_secret_v2.watchdog.data["heartbeat_secret"]
  value_wo_version = 1
}

resource "aws_dynamodb_table" "state" {
  name         = "${local.name}-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 14
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# The permissions boundary caps what this role can ever do, whatever policy is attached to it.
# The apply user may create a role only with this boundary (README), so it cannot mint a role
# more powerful than the watchdog needs.
resource "aws_iam_role" "fn" {
  name                 = "${local.name}-fn"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "fn" {
  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.state.arn]
  }
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.discord_bot_token.arn,
      aws_ssm_parameter.discord_dm_channel_id.arn,
      aws_ssm_parameter.heartbeat_secret.arn,
    ]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.fn.arn}:*"]
  }
}

resource "aws_iam_role_policy" "fn" {
  name   = "${local.name}-fn"
  role   = aws_iam_role.fn.id
  policy = data.aws_iam_policy_document.fn.json
}

data "archive_file" "fn" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/.build/handler.zip"
}

resource "aws_lambda_function" "fn" {
  function_name    = local.name
  role             = aws_iam_role.fn.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.fn.output_path
  source_code_hash = data.archive_file.fn.output_base64sha256
  timeout          = 60
  memory_size      = 128

  environment {
    variables = {
      TABLE                 = aws_dynamodb_table.state.name
      PARAM_DISCORD_TOKEN   = local.param_token
      PARAM_DISCORD_CHANNEL = local.param_channel
      PARAM_HEARTBEAT       = local.param_beat
      HEARTBEAT_MAX_AGE     = tostring(var.heartbeat_max_age_seconds)
      CHECKS                = jsonencode(var.public_checks)
      DAILY_HOUR_UTC        = "12"
      FAIL_THRESHOLD        = "2"
    }
  }

  depends_on = [aws_cloudwatch_log_group.fn, aws_iam_role_policy.fn]
}

# The function URL is public on purpose: the lab calls it from outside AWS. The handler
# refuses a request without the heartbeat secret, and answers 403 to anything else.
resource "aws_lambda_function_url" "fn" {
  function_name      = aws_lambda_function.fn.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.fn.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "url_invoke" {
  statement_id             = "AllowPublicInvokeViaUrl"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.fn.function_name
  principal                = "*"
  invoked_via_function_url = true
}

resource "aws_cloudwatch_event_rule" "tick" {
  name                = "${local.name}-tick"
  schedule_expression = "rate(${var.check_interval_minutes} minutes)"
}

resource "aws_cloudwatch_event_target" "tick" {
  rule = aws_cloudwatch_event_rule.tick.name
  arn  = aws_lambda_function.fn.arn
}

resource "aws_lambda_permission" "tick" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.tick.arn
}

output "heartbeat_url" {
  description = "Where the lab POSTs its heartbeat. Store it with scripts/seed-aws-watchdog-vault.sh --heartbeat-url."
  value       = aws_lambda_function_url.fn.function_url
}
