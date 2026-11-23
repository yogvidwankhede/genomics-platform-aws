variable "name" {
  description = "Name prefix, e.g. gp-dev."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR."
  type        = string
  default     = "10.40.0.0/16"
}

variable "az_count" {
  description = "Number of AZs with a private subnet. Interface endpoints are billed per AZ, so dev uses 1."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 3
    error_message = "az_count must be 1-3."
  }
}

variable "interface_endpoints" {
  description = "AWS services reachable through interface endpoints (no NAT gateway exists)."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "logs", "ecs", "ecs-agent", "ecs-telemetry", "batch", "sts"]
}

variable "kms_key_arn" {
  description = "KMS key for the flow-log group."
  type        = string
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for VPC flow logs."
  type        = number
  default     = 30
}
