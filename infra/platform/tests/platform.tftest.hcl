# Offline plan tests: AWS is mocked, so these run in CI and on a laptop with no credentials.
# They pin the guard-rails that matter for cost and security.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
}

variables {
  trigger_source_dir = "./tests/fixtures/lambda_src"
  api_package_path   = "./tests/fixtures/api.zip"
}

run "dev_plan" {
  command = plan

  variables {
    environment        = "dev"
    owner              = "yogvid"
    cost_center        = "portfolio"
    az_count           = 1
    max_vcpus          = 16
    monthly_budget_usd = 10
    force_destroy      = true
  }

  assert {
    condition     = local.tags["Environment"] == "dev" && local.tags["Owner"] == "yogvid" && local.tags["CostCenter"] == "portfolio" && local.tags["Project"] == "genomics-platform"
    error_message = "mandatory cost-allocation tags missing"
  }

  assert {
    condition     = module.network.interface_endpoint_count == 8
    error_message = "dev should have 8 interface endpoint ENIs (8 services x 1 AZ)"
  }

  assert {
    condition     = length(module.network.private_subnet_ids) == 1
    error_message = "dev runs in a single AZ to halve endpoint cost"
  }

  assert {
    condition     = length(module.ecr.repository_urls) == 11
    error_message = "expected head image + 10 mirrored tool images"
  }

  assert {
    condition     = local.name == "gp-dev"
    error_message = "name prefix"
  }
}

run "prod_plan" {
  command = plan

  variables {
    environment        = "prod"
    owner              = "yogvid"
    cost_center        = "portfolio"
    az_count           = 2
    max_vcpus          = 64
    monthly_budget_usd = 50
    force_destroy      = false
    enable_cloudtrail  = false
  }

  assert {
    condition     = module.network.interface_endpoint_count == 16
    error_message = "prod spreads endpoints over 2 AZs"
  }

  assert {
    condition     = length(module.network.private_subnet_ids) == 2
    error_message = "prod uses 2 AZs"
  }
}

run "rejects_missing_owner_tag" {
  command = plan

  variables {
    environment = "dev"
    owner       = " "
    cost_center = "portfolio"
  }

  expect_failures = [var.owner]
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "staging"
    owner       = "yogvid"
    cost_center = "portfolio"
  }

  expect_failures = [var.environment]
}
