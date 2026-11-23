output "job_queue_arn" {
  description = "Spot job queue ARN."
  value       = aws_batch_job_queue.this.arn
}

output "job_queue_name" {
  description = "Spot job queue name."
  value       = aws_batch_job_queue.this.name
}

output "head_job_definition_arn" {
  description = "Head job definition ARN (revisioned)."
  value       = aws_batch_job_definition.head.arn
}

output "head_job_definition_name" {
  description = "Head job definition name (latest revision)."
  value       = aws_batch_job_definition.head.name
}

output "log_group_name" {
  description = "Batch log group."
  value       = aws_cloudwatch_log_group.jobs.name
}

output "log_group_arn" {
  description = "Batch log group ARN."
  value       = aws_cloudwatch_log_group.jobs.arn
}

output "compute_environment_arn" {
  description = "Spot compute environment ARN."
  value       = aws_batch_compute_environment.spot.arn
}
