data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition
  # inputs  : samplesheets + FASTQs (upload here to trigger a run)
  # work    : Nextflow work dir + cloud cache (disposable)
  # results : published outputs (long-lived, tiered to IA/Glacier)
  data_buckets = {
    inputs  = "${var.name}-inputs-${local.account_id}"
    work    = "${var.name}-work-${local.account_id}"
    results = "${var.name}-results-${local.account_id}"
  }
  logs_bucket      = "${var.name}-logs-${local.account_id}"
  artifacts_bucket = "${var.name}-artifacts-${local.account_id}"
}

# ---- platform data key ----------------------------------------------------------------------
data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_109:Key policies must grant the account root; scoping happens in IAM.
  #checkov:skip=CKV_AWS_111:Key policies must grant the account root; scoping happens in IAM.
  #checkov:skip=CKV_AWS_356:Resource "*" in a key policy refers to this key only.
  statement {
    sid       = "AccountRoot"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }
  statement {
    sid       = "AwsServicesInThisAccount"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type = "Service"
      identifiers = [
        "logs.${local.region}.amazonaws.com",
        "events.amazonaws.com",
        "cloudwatch.amazonaws.com",
        "budgets.amazonaws.com",
        "cloudtrail.amazonaws.com",
        "sns.amazonaws.com",
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "data" {
  description             = "${var.name} platform data (S3, logs, DynamoDB, SNS, SQS, ECR, EBS)"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.name}-data"
  target_key_id = aws_kms_key.data.key_id
}

# ---- data buckets (KMS) ---------------------------------------------------------------------
resource "aws_s3_bucket" "data" {
  #checkov:skip=CKV_AWS_144:Cross-region replication is out of scope (public benchmark data, single region).
  #checkov:skip=CKV2_AWS_62:Event notifications are enabled via EventBridge on the inputs bucket below.
  for_each      = local.data_buckets
  bucket        = each.value
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_versioning" "data" {
  for_each = aws_s3_bucket.data
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  for_each = aws_s3_bucket.data
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_logging" "data" {
  for_each      = aws_s3_bucket.data
  bucket        = each.value.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access/${each.key}/"
}

resource "aws_s3_bucket_lifecycle_configuration" "inputs" {
  bucket = aws_s3_bucket.data["inputs"].id
  rule {
    id     = "tier-inputs"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "work" {
  bucket = aws_s3_bucket.data["work"].id
  rule {
    id     = "expire-work"
    status = "Enabled"
    filter {}
    expiration {
      days = var.work_expiration_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.data["results"].id
  rule {
    id     = "tier-results"
    status = "Enabled"
    filter {}
    transition {
      days          = var.results_ia_days
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = var.results_glacier_days
      storage_class = "GLACIER_IR"
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

# EventBridge delivery is what drives the event-driven trigger.
resource "aws_s3_bucket_notification" "inputs" {
  bucket      = aws_s3_bucket.data["inputs"].id
  eventbridge = true
}

# ---- logs bucket (SSE-S3: S3 server access logging cannot target SSE-KMS buckets) -----------
resource "aws_s3_bucket" "logs" {
  #checkov:skip=CKV_AWS_18:This is the access-log destination; logging it to itself would loop.
  #checkov:skip=CKV_AWS_144:Cross-region replication out of scope.
  #checkov:skip=CKV_AWS_145:S3 server access logging only supports SSE-S3 destination buckets.
  #checkov:skip=CKV2_AWS_62:No consumers for log-bucket notifications.
  bucket        = local.logs_bucket
  force_destroy = var.force_destroy
}

# ---- artifacts bucket: instance bootstrap (AWS CLI bundle), read anonymously via VPCe --------
resource "aws_s3_bucket" "artifacts" {
  #checkov:skip=CKV_AWS_144:Cross-region replication out of scope.
  #checkov:skip=CKV_AWS_145:Read by EC2 user-data without credentials, which cannot use SSE-KMS.
  #checkov:skip=CKV2_AWS_62:No consumers for artifact-bucket notifications.
  bucket        = local.artifacts_bucket
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_logging" "artifacts" {
  bucket        = aws_s3_bucket.artifacts.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access/artifacts/"
}

locals {
  sse_s3_buckets = { logs = aws_s3_bucket.logs, artifacts = aws_s3_bucket.artifacts }
  all_buckets    = merge(aws_s3_bucket.data, local.sse_s3_buckets)
}

resource "aws_s3_bucket_versioning" "sse_s3" {
  for_each = local.sse_s3_buckets
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "sse_s3" {
  for_each = local.sse_s3_buckets
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "tier-and-expire-logs"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = 365
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire-old-artifact-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ---- controls shared by every bucket --------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "all" {
  for_each                = local.all_buckets
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "all" {
  for_each = local.all_buckets
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "bucket" {
  for_each = local.all_buckets

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "logs" ? [1] : []
    content {
      sid       = "S3ServerAccessLogs"
      actions   = ["s3:PutObject"]
      resources = ["${each.value.arn}/s3-access/*"]
      principals {
        type        = "Service"
        identifiers = ["logging.s3.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account_id]
      }
    }
  }

  dynamic "statement" {
    for_each = each.key == "logs" ? [1] : []
    content {
      sid       = "CloudTrailAclCheck"
      actions   = ["s3:GetBucketAcl"]
      resources = [each.value.arn]
      principals {
        type        = "Service"
        identifiers = ["cloudtrail.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account_id]
      }
    }
  }

  dynamic "statement" {
    for_each = each.key == "logs" ? [1] : []
    content {
      sid       = "CloudTrailWrite"
      actions   = ["s3:PutObject"]
      resources = ["${each.value.arn}/cloudtrail/AWSLogs/${local.account_id}/*"]
      principals {
        type        = "Service"
        identifiers = ["cloudtrail.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "s3:x-amz-acl"
        values   = ["bucket-owner-full-control"]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account_id]
      }
    }
  }

  # Batch instances fetch the AWS CLI bundle in user-data, before they have a CLI to sign with.
  # Unsigned reads are allowed only for bootstrap/* and only through this VPC's S3 endpoint.
  dynamic "statement" {
    for_each = each.key == "artifacts" ? [1] : []
    content {
      sid       = "BootstrapReadFromVpcEndpoint"
      actions   = ["s3:GetObject"]
      resources = ["${each.value.arn}/bootstrap/*"]
      principals {
        type        = "*"
        identifiers = ["*"]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceVpce"
        values   = [var.s3_vpce_id]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "all" {
  for_each = local.all_buckets
  bucket   = each.value.id
  policy   = data.aws_iam_policy_document.bucket[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.all]
}
