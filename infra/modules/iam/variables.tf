variable "name" {
  description = "Name prefix, e.g. gp-dev."
  type        = string
}

variable "bucket_arns" {
  description = "Map with inputs/work/results bucket ARNs."
  type        = map(string)
}

variable "kms_key_arn" {
  description = "Platform data key."
  type        = string
}

variable "ecr_repository_arns" {
  description = "Repositories the instances may pull from."
  type        = list(string)
}

variable "batch_log_group_name" {
  description = "Log group Batch jobs write to (head job reads task logs for error reports)."
  type        = string
}
