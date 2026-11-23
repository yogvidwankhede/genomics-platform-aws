output "state_bucket" {
  description = "Bucket name to put in envs/<env>.backend.hcl."
  value       = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  description = "KMS key encrypting the state objects."
  value       = aws_kms_key.state.arn
}

output "github_plan_role_arn" {
  description = "Set as the AWS_PLAN_ROLE_ARN repository variable."
  value       = aws_iam_role.github_plan.arn
}

output "github_apply_role_arns" {
  description = "Set each as AWS_APPLY_ROLE_ARN on the matching GitHub Environment."
  value       = { for env, role in aws_iam_role.github_apply : env => role.arn }
}
