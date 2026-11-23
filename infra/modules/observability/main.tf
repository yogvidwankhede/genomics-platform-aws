data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region    = data.aws_region.current.region
  namespace = "GenomicsPlatform"
  dims      = { Environment = var.environment }
}

# ---- alarms ---------------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "run_failed" {
  alarm_name          = "${var.name}-run-failed"
  alarm_description   = "A pipeline run failed. Triage: docs/runbook.md#run-failed"
  namespace           = local.namespace
  metric_name         = "RunsFailed"
  dimensions          = local.dims
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "queue_stuck" {
  alarm_name          = "${var.name}-queue-stuck"
  alarm_description   = "Oldest RUNNABLE Batch job waited > ${var.queue_stuck_seconds}s (Spot capacity / CE misconfig). docs/runbook.md#queue-stuck"
  namespace           = local.namespace
  metric_name         = "OldestRunnableJobAgeSeconds"
  dimensions          = local.dims
  statistic           = "Maximum"
  period              = 600
  evaluation_periods  = 2
  threshold           = var.queue_stuck_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each            = var.function_names
  alarm_name          = "${var.name}-${replace(each.key, "_", "-")}-errors"
  alarm_description   = "Lambda ${each.value} raised errors. docs/runbook.md#lambda-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.name}-trigger-dlq"
  alarm_description   = "Events landed in the trigger DLQ. docs/runbook.md#dlq"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = var.dlq_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
}

# ---- dashboard ------------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.name}-platform"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Runs by outcome"
          region = local.region
          stat   = "Sum"
          period = 3600
          view   = "timeSeries"
          metrics = [
            [local.namespace, "RunsSubmitted", "Environment", var.environment],
            [local.namespace, "RunsSucceeded", "Environment", var.environment],
            [local.namespace, "RunsFailed", "Environment", var.environment],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "Run wall time (s)"
          region  = local.region
          period  = 3600
          view    = "timeSeries"
          metrics = [[local.namespace, "RunDurationSeconds", "Environment", var.environment, { stat = "Maximum" }]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title       = "Queue ${var.job_queue_name}: oldest RUNNABLE job (s)"
          region      = local.region
          stat        = "Maximum"
          period      = 600
          view        = "timeSeries"
          metrics     = [[local.namespace, "OldestRunnableJobAgeSeconds", "Environment", var.environment]]
          annotations = { horizontal = [{ label = "stuck", value = var.queue_stuck_seconds }] }
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title   = "Lambda errors"
          region  = local.region
          stat    = "Sum"
          period  = 300
          view    = "timeSeries"
          metrics = [for k, fn in var.function_names : ["AWS/Lambda", "Errors", "FunctionName", fn]]
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "Recent head-job log lines containing ERROR"
          region = local.region
          query  = "SOURCE '${var.batch_log_group_name}' | fields @timestamp, @logStream, @message | filter @message like /ERROR/ | sort @timestamp desc | limit 50"
          view   = "table"
        }
      },
    ]
  })
}

# ---- cost guard-rail ------------------------------------------------------------------------
data "aws_iam_policy_document" "budget_sns" {
  statement {
    actions   = ["sns:Publish"]
    resources = [var.alarm_topic_arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com", "cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alarms" {
  arn    = var.alarm_topic_arn
  policy = data.aws_iam_policy_document.budget_sns.json
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "cost_filter" {
    for_each = var.budget_cost_filter_tag == null ? [] : [var.budget_cost_filter_tag]
    content {
      name   = "TagKeyValue"
      values = [cost_filter.value]
    }
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_sns_topic_arns  = [var.alarm_topic_arn]
      subscriber_email_addresses = var.budget_emails
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [var.alarm_topic_arn]
    subscriber_email_addresses = var.budget_emails
  }
}

# ---- audit ----------------------------------------------------------------------------------
resource "aws_cloudtrail" "this" {
  #checkov:skip=CKV2_AWS_10:Trail is delivered to S3 with log-file validation; CloudWatch Logs delivery is optional and adds cost.
  #checkov:skip=CKV_AWS_252:SNS delivery notifications are not needed for this trail.
  count                         = var.enable_cloudtrail ? 1 : 0
  name                          = "${var.name}-trail"
  s3_bucket_name                = var.logs_bucket
  s3_key_prefix                 = "cloudtrail"
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = var.kms_key_arn
}
