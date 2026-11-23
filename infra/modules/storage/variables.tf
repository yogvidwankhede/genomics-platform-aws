variable "name" {
  description = "Name prefix, e.g. gp-dev."
  type        = string
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to delete non-empty buckets (true for dev teardown)."
  type        = bool
  default     = false
}

variable "work_expiration_days" {
  description = "Nextflow work/ intermediates are disposable; expire them after this many days."
  type        = number
  default     = 7
}

variable "results_ia_days" {
  description = "Move results to STANDARD_IA after N days."
  type        = number
  default     = 30
}

variable "results_glacier_days" {
  description = "Move results to GLACIER_IR after N days."
  type        = number
  default     = 90
}

variable "s3_vpce_id" {
  description = "S3 gateway endpoint allowed to read the instance bootstrap artifacts anonymously."
  type        = string
}
