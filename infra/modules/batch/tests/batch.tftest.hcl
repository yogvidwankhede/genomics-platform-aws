mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
}

variables {
  name                 = "gp-test"
  subnet_ids           = ["subnet-0123456789abcdef0"]
  security_group_ids   = ["sg-0123456789abcdef0"]
  instance_profile_arn = "arn:aws:iam::123456789012:instance-profile/gp-test"
  kms_key_arn          = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  artifacts_bucket     = "gp-test-artifacts"
  head_image           = "123456789012.dkr.ecr.us-east-1.amazonaws.com/gp/nextflow-head:0.1.0"
  head_role_arn        = "arn:aws:iam::123456789012:role/gp-test-nf-head"
}

run "spot_scale_to_zero" {
  command = plan

  assert {
    condition     = aws_batch_compute_environment.spot.compute_resources[0].type == "SPOT"
    error_message = "compute must be Spot only"
  }
  assert {
    condition     = aws_batch_compute_environment.spot.compute_resources[0].min_vcpus == 0 && aws_batch_compute_environment.spot.compute_resources[0].desired_vcpus == 0
    error_message = "compute must scale to zero when idle"
  }
  assert {
    condition     = aws_batch_compute_environment.spot.compute_resources[0].max_vcpus == 16
    error_message = "default vCPU ceiling is the cost guard-rail"
  }
  assert {
    condition     = aws_batch_compute_environment.spot.compute_resources[0].allocation_strategy == "SPOT_PRICE_CAPACITY_OPTIMIZED"
    error_message = "use price-capacity-optimized Spot allocation"
  }
}

run "hardened_instances" {
  command = plan

  assert {
    condition     = aws_launch_template.compute.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required"
  }
  assert {
    condition     = aws_launch_template.compute.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "containers must not reach IMDS"
  }
  assert {
    condition     = aws_launch_template.compute.block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "EBS must be encrypted"
  }
}

run "head_job_retries_spot_reclaim_and_times_out" {
  command = plan

  assert {
    condition     = aws_batch_job_definition.head.timeout[0].attempt_duration_seconds == 14400
    error_message = "head job needs a wall-time cap"
  }
  assert {
    condition     = aws_batch_job_definition.head.retry_strategy[0].attempts == 3
    error_message = "head job retries Spot reclaims"
  }
}
