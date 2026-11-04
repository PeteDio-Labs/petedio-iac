# AWS credit guardrails (PET-803, epic PET-802). The Dream It Ship It account runs on a $100
# credit that ends 2027-04-20. Two budgets and a cost anomaly monitor warn before the credit
# runs out. Alerts go by email only: this root creates no SNS topic and no function.
#
# ⚠ Both budgets measure gross spend: `include_credit = false` stops AWS from netting credits
# against usage. With credits netted, the account bills $0 and a budget never fires until the
# credit is gone, which is the moment the alert is for.
#
# `petedio-monthly-5usd` (README, step 1) was created by hand and stays outside this root.
# Importing it would bring a budget that predates this config under management, so it is a
# separate decision.
#
# The apply user needs the `budgets:` and `ce:` actions listed in README.md, "Budget and
# anomaly permissions". Plan only until Pedro adds them.

locals {
  credit_tags = {
    project = "credit-plan"
    expires = var.credit_expires
  }
}

resource "aws_budgets_budget" "credit_burn" {
  name         = "petedio-credit-burn"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
    include_refund = false
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }

  tags = local.credit_tags
}

# AWS has no cumulative budget type. An ANNUALLY budget accumulates from its start date, and
# the end date stops it when the credit expires, so it measures the whole credit period.
resource "aws_budgets_budget" "credit_cumulative" {
  name         = "petedio-credit-cumulative"
  budget_type  = "COST"
  limit_amount = tostring(var.cumulative_budget_usd)
  limit_unit   = "USD"
  time_unit    = "ANNUALLY"

  time_period_start = var.credit_period_start
  time_period_end   = "${var.credit_expires}_00:00"

  cost_types {
    include_credit = false
    include_refund = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  tags = local.credit_tags
}

# Cost Anomaly Detection: one monitor over every AWS service, one daily email digest. Email
# subscribers support DAILY or WEEKLY only. IMMEDIATE needs an SNS topic.
resource "aws_ce_anomaly_monitor" "services" {
  name              = "petedio-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = local.credit_tags
}

resource "aws_ce_anomaly_subscription" "daily" {
  name             = "petedio-anomaly-daily"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  dynamic "subscriber" {
    for_each = var.budget_alert_emails
    content {
      type    = "EMAIL"
      address = subscriber.value
    }
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }

  tags = local.credit_tags
}
