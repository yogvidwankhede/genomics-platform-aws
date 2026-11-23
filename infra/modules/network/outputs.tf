output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs for Batch compute."
  value       = aws_subnet.private[*].id
}

output "compute_security_group_id" {
  description = "Security group for Batch instances."
  value       = aws_security_group.compute.id
}

output "s3_endpoint_id" {
  description = "S3 gateway endpoint ID (used in bucket policies)."
  value       = aws_vpc_endpoint.s3.id
}

output "interface_endpoint_count" {
  description = "Billable interface endpoint ENIs (endpoints x AZs)."
  value       = length(var.interface_endpoints) * var.az_count
}
