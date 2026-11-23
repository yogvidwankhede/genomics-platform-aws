output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}

output "alarm_names" {
  description = "All alarm names."
  value = concat(
    [aws_cloudwatch_metric_alarm.run_failed.alarm_name, aws_cloudwatch_metric_alarm.queue_stuck.alarm_name, aws_cloudwatch_metric_alarm.dlq_not_empty.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_errors : a.alarm_name],
  )
}

output "budget_name" {
  description = "AWS Budget name."
  value       = aws_budgets_budget.monthly.name
}
