# A small budget on the site's own tagged resources, so the first bill after the credit ends is not a surprise
# (docs/hosting-and-exit-plan.md in pdlabs-portfolio). Off until budget_limit_usd is above 0.
resource "aws_budgets_budget" "site" {
  count = var.budget_limit_usd > 0 ? 1 : 0

  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_emails
  }

  lifecycle {
    precondition {
      condition     = length(var.budget_emails) > 0
      error_message = "budget_emails must hold at least one address when budget_limit_usd is above 0."
    }
  }
}
