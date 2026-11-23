variable "name" {
  description = "Name prefix, e.g. gp-dev."
  type        = string
}

variable "environment" {
  description = "Environment name (dev/prod)."
  type        = string
}

variable "kms_key_arn" {
  description = "Platform data key."
  type        = string
}

variable "bucket_names" {
  description = "Map with inputs/work/results bucket names."
  type        = map(string)
}

variable "bucket_arns" {
  description = "Map with inputs/work/results bucket ARNs."
  type        = map(string)
}

variable "job_queue_arn" {
  description = "Batch queue for head jobs."
  type        = string
}

variable "job_queue_name" {
  description = "Batch queue name (passed to Nextflow as aws_queue)."
  type        = string
}

variable "head_job_definition_name" {
  description = "Head job definition name; latest ACTIVE revision is used."
  type        = string
}

variable "batch_log_group_name" {
  description = "Log group Nextflow task jobs should log to."
  type        = string
}

variable "trigger_source_dir" {
  description = "Path to services/trigger/src (pure-stdlib + boto3 handlers)."
  type        = string
}

variable "api_package_path" {
  description = "Path to the pre-built API Lambda zip (make build-api)."
  type        = string
}

variable "notification_email" {
  description = "Optional email subscribed to run notifications (confirm the subscription email)."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention for Lambda logs."
  type        = number
  default     = 30
}

variable "reserve_concurrency" {
  description = "Reserve Lambda concurrency per function. New accounts have a 10-execution account limit and AWS refuses any reservation, so set false there."
  type        = bool
  default     = true
}

variable "submit_concurrency" {
  description = "Reserved concurrency for the submit Lambda: caps how many runs can start at once."
  type        = number
  default     = 2
}

variable "pipeline_profile" {
  description = "Nextflow profile(s) used for event-triggered runs."
  type        = string
  default     = "awsbatch"
}

variable "pipeline_params" {
  description = "Extra pipeline params (JSON-serialisable) stored in SSM and applied to every run, e.g. reference paths."
  type        = map(string)
  default     = {}
}
