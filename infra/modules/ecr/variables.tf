variable "repositories" {
  description = "Repository names to create (platform images + mirrors of pinned public images)."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS key for repository encryption."
  type        = string
}

variable "keep_images" {
  description = "Untagged/old images beyond this count are expired."
  type        = number
  default     = 10
}

variable "force_delete" {
  description = "Allow destroy to delete repositories that still contain images."
  type        = bool
  default     = false
}
