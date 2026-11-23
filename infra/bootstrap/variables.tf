variable "region" {
  description = "AWS region for the state bucket and IAM resources."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short project slug used as a name prefix."
  type        = string
  default     = "gp"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) allowed to assume the CI roles via OIDC."
  type        = string
  default     = "yogvidwankhede/genomics-platform-aws"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name."
  }
}

variable "environments" {
  description = "Environments that get their own state key and apply role."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "owner" {
  description = "Owner tag value (cost allocation)."
  type        = string
  default     = "yogvid"
}

variable "force_destroy_state" {
  description = "Teardown only: allow destroying the state bucket with its object versions."
  type        = bool
  default     = false
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the token.actions.githubusercontent.com provider."
  type        = bool
  default     = true
}
