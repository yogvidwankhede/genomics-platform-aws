terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
  }

  # Bootstrap is the one stack that cannot store its state in the bucket it creates.
  # Keep local state here, or migrate it into the bucket after the first apply
  # (`terraform init -migrate-state -backend-config=...`, see docs/runbook.md).
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
