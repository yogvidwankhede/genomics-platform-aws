output "kms_key_arn" {
  description = "Platform data KMS key ARN."
  value       = aws_kms_key.data.arn
}

output "bucket_names" {
  description = "Map of logical name -> bucket name."
  value = merge(
    { for k, b in aws_s3_bucket.data : k => b.bucket },
    { logs = aws_s3_bucket.logs.bucket, artifacts = aws_s3_bucket.artifacts.bucket },
  )
}

output "logs_bucket_with_policy" {
  description = "Logs bucket name, available only after its bucket policy (CloudTrail access) is attached."
  value       = aws_s3_bucket_policy.all["logs"].bucket
}

output "bucket_arns" {
  description = "Map of logical name -> bucket ARN."
  value = merge(
    { for k, b in aws_s3_bucket.data : k => b.arn },
    { logs = aws_s3_bucket.logs.arn, artifacts = aws_s3_bucket.artifacts.arn },
  )
}
