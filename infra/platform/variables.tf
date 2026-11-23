variable "environment" {
  description = "Environment name."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short name prefix."
  type        = string
  default     = "gp"
}

# ---- mandatory cost-allocation tags ---------------------------------------------------------
variable "owner" {
  description = "Owner tag (mandatory)."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner tag is mandatory."
  }
}

variable "cost_center" {
  description = "CostCenter tag (mandatory)."
  type        = string

  validation {
    condition     = length(trimspace(var.cost_center)) > 0
    error_message = "cost_center tag is mandatory."
  }
}

# ---- sizing / cost --------------------------------------------------------------------------
variable "az_count" {
  description = "AZs (interface endpoints are billed per AZ-hour)."
  type        = number
  default     = 1
}

variable "max_vcpus" {
  description = "Batch compute ceiling."
  type        = number
  default     = 16
}

variable "monthly_budget_usd" {
  description = "AWS Budgets limit."
  type        = number
  default     = 10
}

variable "force_destroy" {
  description = "Allow destroy of non-empty buckets/repos (dev only)."
  type        = bool
  default     = false
}

variable "enable_cloudtrail" {
  description = "Create the account trail from this environment."
  type        = bool
  default     = true
}

# ---- pipeline / images ----------------------------------------------------------------------
variable "pipeline_version" {
  description = "Tag of the gp/nextflow-head image (pipeline release)."
  type        = string
  default     = "0.1.0"
}

variable "mirrored_images" {
  description = "Public images (registry/path, no tag) mirrored into ECR under mirror/."
  type        = list(string)
  default = [
    "community.wave.seqera.io/library/fastqc",
    "community.wave.seqera.io/library/fastp",
    "community.wave.seqera.io/library/htslib_samtools",
    "community.wave.seqera.io/library/bwa-mem2_htslib_samtools",
    "community.wave.seqera.io/library/gatk4-lite",
    "community.wave.seqera.io/library/gatk4-lite_samtools",
    "community.wave.seqera.io/library/bcftools_htslib",
    "community.wave.seqera.io/library/multiqc",
    "quay.io/biocontainers/hap.py",
    "docker.io/google/deepvariant",
  ]
}

variable "pipeline_params" {
  description = "Default params for event-triggered runs (e.g. reference/truth S3 URIs)."
  type        = map(string)
  default     = {}
}

variable "notification_email" {
  description = "Optional email for run notifications and alarms."
  type        = string
  default     = null
}

variable "trigger_source_dir" {
  description = "Lambda source for the trigger handlers."
  type        = string
  default     = "../../services/trigger/src"
}

variable "api_package_path" {
  description = "Pre-built API Lambda zip (make build-api)."
  type        = string
  default     = "../../build/api.zip"
}
