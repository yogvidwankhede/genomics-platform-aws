mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name       = "gp-test"
  s3_vpce_id = "vpce-0123456789abcdef0"
}

run "every_bucket_is_locked_down" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_public_access_block.data) == 3
    error_message = "all 3 data buckets need a public access block"
  }
  assert {
    condition = alltrue([for b in concat(values(aws_s3_bucket_public_access_block.data), [aws_s3_bucket_public_access_block.logs, aws_s3_bucket_public_access_block.artifacts]) :
    b.block_public_acls && b.block_public_policy && b.ignore_public_acls && b.restrict_public_buckets])
    error_message = "public access must be fully blocked"
  }
  assert {
    condition     = alltrue([for v in aws_s3_bucket_versioning.data : v.versioning_configuration[0].status == "Enabled"]) && aws_s3_bucket_versioning.logs.versioning_configuration[0].status == "Enabled" && aws_s3_bucket_versioning.artifacts.versioning_configuration[0].status == "Enabled"
    error_message = "all buckets must be versioned"
  }
  assert {
    condition     = alltrue([for e in aws_s3_bucket_server_side_encryption_configuration.data : one(e.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"])
    error_message = "data buckets must use SSE-KMS"
  }
  assert {
    condition     = aws_kms_key.data.enable_key_rotation
    error_message = "KMS rotation must be on"
  }
}

run "lifecycle_tiers_results_and_expires_work" {
  command = plan

  assert {
    condition     = [for t in one(aws_s3_bucket_lifecycle_configuration.results.rule).transition : t.storage_class] == ["STANDARD_IA", "GLACIER_IR"]
    error_message = "results tier to IA then Glacier IR"
  }
  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.work.rule).expiration[0].days == 7
    error_message = "work dir expires after 7 days"
  }
  assert {
    condition     = aws_s3_bucket.data["inputs"].force_destroy == false
    error_message = "force_destroy defaults off"
  }
}
