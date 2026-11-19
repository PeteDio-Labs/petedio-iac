# CloudWatch alarms for the off-site watchdog. The Lambda writes metrics in the
# PeteDio/Watchdog namespace (embedded metric format, so no PutMetricData call and no extra
# IAM on the function role). These alarms read them and email an SNS topic.
#
# Cost: about $0.30 a month per custom metric (one heartbeat metric, one per check) and $0.10
# a month per alarm, so $2 to $3 a month with three public checks. CloudWatch Synthetics
# canaries would cost about $10 a month each at a 5-minute rate, and the Lambda probes already
# cover that job, so this module does not use them.
#
# The apply user needs the `cloudwatch:` and `sns:` actions in README.md, "Alarm permissions".

# An admin creates both SNS topics by hand (README, "Alarm permissions") and this root only
# reads them. A user who can create or delete a topic can set its access policy at creation and
# grant itself sns:Publish, so topic creation stays outside the apply user's grants.
#
# An email subscription stays pending until its owner confirms the message AWS sends, so a plan
# that adds one does not prove the alert reaches anyone.
data "aws_sns_topic" "alarms" {
  name = "${local.name}-alarms"
}

resource "aws_sns_topic_subscription" "alarm_email" {
  for_each = toset(var.budget_alert_emails)

  topic_arn = data.aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

# The lab is dark when its heartbeat is stale. A missing datapoint also alarms, so a dead
# checker cannot read as a healthy lab. Two periods in a row match the Discord alert's
# FAIL_THRESHOLD of 2.
resource "aws_cloudwatch_metric_alarm" "lab_dark" {
  alarm_name          = "${local.name}-lab-dark"
  alarm_description   = "No lab heartbeat for more than ${var.heartbeat_max_age_seconds} s, or the checker stopped reporting. The failover site serves the dashboard meanwhile (PET-934)."
  namespace           = "PeteDio/Watchdog"
  metric_name         = "HeartbeatAgeSeconds"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.heartbeat_max_age_seconds
  period              = var.check_interval_minutes * 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "breaching"

  alarm_actions = concat([data.aws_sns_topic.alarms.arn], var.extra_alarm_action_arns)
  ok_actions    = [data.aws_sns_topic.alarms.arn]
}

# One alarm per public check, such as Authentik on EC2. CheckUp is 1 when the probe passed.
resource "aws_cloudwatch_metric_alarm" "check_down" {
  for_each = { for c in var.public_checks : c.name => c }

  alarm_name          = "${local.name}-check-${each.key}"
  alarm_description   = "The off-site probe of ${each.key} failed twice in a row, or the checker stopped reporting."
  namespace           = "PeteDio/Watchdog"
  metric_name         = "CheckUp"
  dimensions          = { Check = each.key }
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = var.check_interval_minutes * 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "breaching"

  alarm_actions = [data.aws_sns_topic.alarms.arn]
  ok_actions    = [data.aws_sns_topic.alarms.arn]
}

# Billing metrics exist only in us-east-1, and an alarm can notify only a topic in its own
# region, so this one has its own topic. EstimatedCharges is gross spend before credits, the
# same basis as the budgets in budgets.tf. It needs "Receive Billing Alerts" turned on once in
# the account's billing preferences.
data "aws_sns_topic" "billing" {
  provider = aws.us_east_1
  name     = "${local.name}-billing"
}

resource "aws_sns_topic_subscription" "billing_email" {
  provider = aws.us_east_1
  for_each = toset(var.budget_alert_emails)

  topic_arn = data.aws_sns_topic.billing.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_metric_alarm" "billing" {
  provider = aws.us_east_1

  alarm_name          = "${local.name}-billing"
  alarm_description   = "Estimated gross AWS charges this month passed ${var.billing_alarm_usd} USD. Credits expire ${var.credit_expires}."
  namespace           = "AWS/Billing"
  metric_name         = "EstimatedCharges"
  dimensions          = { Currency = "USD" }
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.billing_alarm_usd
  period              = 21600
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching" # the metric publishes a few times a day, so gaps are normal

  alarm_actions = [data.aws_sns_topic.billing.arn]
}
