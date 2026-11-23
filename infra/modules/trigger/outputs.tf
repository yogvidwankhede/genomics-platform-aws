output "runs_table_name" {
  description = "DynamoDB run registry."
  value       = aws_dynamodb_table.runs.name
}

output "topic_arn" {
  description = "SNS topic for run success/failure."
  value       = aws_sns_topic.runs.arn
}

output "dlq_name" {
  description = "Dead-letter queue for failed event deliveries/invocations."
  value       = aws_sqs_queue.dlq.name
}

output "api_url" {
  description = "IAM-authenticated API URL."
  value       = aws_lambda_function_url.api.function_url
}

output "function_names" {
  description = "Lambda function names."
  value       = merge({ for k, f in aws_lambda_function.fn : k => f.function_name }, { api = aws_lambda_function.api.function_name })
}

output "config_parameter" {
  description = "SSM parameter holding runtime config."
  value       = aws_ssm_parameter.config.name
}
