output "instance_profile_arn" {
  description = "Instance profile for the Batch compute environment."
  value       = aws_iam_instance_profile.instance.arn
}

output "instance_role_arn" {
  description = "Instance role ARN."
  value       = aws_iam_role.instance.arn
}

output "head_role_arn" {
  description = "Job role for the Nextflow head job."
  value       = aws_iam_role.head.arn
}

output "task_role_arn" {
  description = "Job role for pipeline task containers."
  value       = aws_iam_role.task.arn
}
