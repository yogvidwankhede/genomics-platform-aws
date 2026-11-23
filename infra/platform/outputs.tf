output "buckets" {
  description = "Platform buckets."
  value       = module.storage.bucket_names
}

output "ecr_registry" {
  description = "ECR registry host."
  value       = local.registry
}

output "head_repository_url" {
  description = "Where to push the nextflow-head image."
  value       = module.ecr.repository_urls[local.head_repository]
}

output "job_queue" {
  description = "Batch job queue."
  value       = module.batch.job_queue_name
}

output "runs_table" {
  description = "DynamoDB run registry."
  value       = module.trigger.runs_table_name
}

output "api_url" {
  description = "IAM-authenticated API URL (SigV4)."
  value       = module.trigger.api_url
}

output "dashboard" {
  description = "CloudWatch dashboard."
  value       = module.observability.dashboard_name
}

output "interface_endpoint_enis" {
  description = "Billable interface endpoint ENIs (x $0.01/h each in us-east-1)."
  value       = module.network.interface_endpoint_count
}
