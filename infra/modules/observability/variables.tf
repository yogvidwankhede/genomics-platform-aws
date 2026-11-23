variable "name" {
  description = "Name prefix, e.g. gp-dev."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "kms_key_arn" {
  description = "Platform data key."
  type        = string
}

variable "alarm_topic_arn" {
  description = "SNS topic for alarms and budget notifications."
  type        = string
}

variable "function_names" {
  description = "Lambda functions to alarm on."
  type        = map(string)
}

variable "dlq_name" {
  description = "Trigger dead-letter queue."
  type        = string
}

variable "job_queue_name" {
  description = "Batch queue name (dashboard label)."
  type        = string
}

variable "batch_log_group_name" {
  description = "Batch log group (dashboard log widget)."
  type        = string
}

variable "monthly_budget_usd" {
  description = "AWS Budgets monthly cost limit."
  type        = number
  default     = 10
}

variable "budget_emails" {
  description = "Emails notified by the budget (in addition to the SNS topic)."
  type        = list(string)
  default     = []
}

variable "budget_cost_filter_tag" {
  description = "Optional cost-allocation tag filter, e.g. \"user:Project$genomics-platform\". Null = whole account."
  type        = string
  default     = null
}

variable "queue_stuck_seconds" {
  description = "Alarm when the oldest RUNNABLE job has waited this long."
  type        = number
  default     = 1800
}

variable "enable_cloudtrail" {
  description = "Create a multi-region management-event trail (one per account is enough)."
  type        = bool
  default     = true
}

variable "logs_bucket" {
  description = "Bucket receiving CloudTrail logs."
  type        = string
}
