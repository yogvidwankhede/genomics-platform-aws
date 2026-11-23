variable "name" {
  description = "Name prefix, e.g. gp-dev."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for compute."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups for compute instances."
  type        = list(string)
}

variable "instance_profile_arn" {
  description = "ECS instance profile."
  type        = string
}

variable "instance_types" {
  description = "Spot instance families/types Batch may pick from (diversity = fewer interruptions)."
  type        = list(string)
  default     = ["m6i", "m5", "c6i", "c5", "r6i", "r5"]
}

variable "max_vcpus" {
  description = "Hard ceiling on concurrent vCPUs: the main cost guard-rail."
  type        = number
  default     = 16
}

variable "root_volume_gb" {
  description = "Root EBS volume (Docker images + task scratch)."
  type        = number
  default     = 100
}

variable "kms_key_arn" {
  description = "KMS key for EBS and logs."
  type        = string
}

variable "artifacts_bucket" {
  description = "Bucket holding bootstrap/awscli-exe-linux-x86_64.zip."
  type        = string
}

variable "head_image" {
  description = "Nextflow head image URI (ECR, immutable tag)."
  type        = string
}

variable "head_role_arn" {
  description = "Job role for the Nextflow head job."
  type        = string
}

variable "head_vcpus" {
  description = "vCPUs for the head job."
  type        = number
  default     = 1
}

variable "head_memory_mib" {
  description = "Memory for the head job."
  type        = number
  default     = 2048
}

variable "head_timeout_seconds" {
  description = "Kill a run that exceeds this wall time (cost guard-rail)."
  type        = number
  default     = 14400
}

variable "log_retention_days" {
  description = "Retention for Batch job logs."
  type        = number
  default     = 30
}
