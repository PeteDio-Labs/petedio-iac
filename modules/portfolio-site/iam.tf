# Two ways for GitHub Actions to deploy (var.deploy_auth):
#   oidc: a short-lived OIDC token assumes a role, so no access key exists. Use this on any
#         account that allows an IAM OIDC provider.
#   user: a deploy-only IAM user. Some accounts deny the provider through a service control
#         policy (PET-816), so this path exists. Terraform creates the user but never the
#         access key, so no secret reaches state: scripts/portfolio-deploy-key.sh makes it.
locals {
  use_oidc = var.deploy_auth == "oidc"
  use_user = var.deploy_auth == "user"
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = local.use_oidc && var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

locals {
  oidc_provider_arn = local.use_oidc && var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "trust" {
  count = local.use_oidc ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # One repo, one branch. A pull request or fork run sends a different sub and is refused.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  count              = local.use_oidc ? 1 : 0
  name               = "${var.name}-deploy"
  assume_role_policy = data.aws_iam_policy_document.trust[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.site.arn]
  }

  statement {
    sid       = "WriteObjects"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
  }

  # GetInvalidation: the deploy workflow waits for the invalidation to complete.
  statement {
    sid       = "Invalidate"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = [aws_cloudfront_distribution.site.arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  count  = local.use_oidc ? 1 : 0
  name   = "deploy"
  role   = aws_iam_role.deploy[0].id
  policy = data.aws_iam_policy_document.deploy.json
}

resource "aws_iam_user" "deploy" {
  count = local.use_user ? 1 : 0
  name  = "${var.name}-deploy"
  tags  = var.tags
}

resource "aws_iam_user_policy" "deploy" {
  count  = local.use_user ? 1 : 0
  name   = "deploy"
  user   = aws_iam_user.deploy[0].name
  policy = data.aws_iam_policy_document.deploy.json
}
