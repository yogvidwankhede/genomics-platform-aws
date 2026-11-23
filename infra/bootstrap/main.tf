data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  tags = {
    Project     = "genomics-platform"
    Environment = "shared"
    Owner       = var.owner
    CostCenter  = "portfolio"
    ManagedBy   = "terraform"
    Stack       = "bootstrap"
  }
  state_bucket = "${var.project}-tfstate-${local.account_id}-${var.region}"
}

# ---------------------------------------------------------------------------------------------
# Terraform state: versioned, KMS-encrypted, TLS-only, public access blocked.
# Locking uses the S3-native lockfile (Terraform >= 1.10), so no DynamoDB lock table is needed.
# ---------------------------------------------------------------------------------------------
resource "aws_kms_key" "state" {
  description             = "Terraform state encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.state_key.json
}

data "aws_iam_policy_document" "state_key" {
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
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18:State bucket access is audited through CloudTrail data events, not S3 access logs.
  #checkov:skip=CKV_AWS_144:Cross-region replication is out of scope for a single-region portfolio account.
  #checkov:skip=CKV2_AWS_62:No consumers for state-bucket event notifications.
  bucket = local.state_bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
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
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

# ---------------------------------------------------------------------------------------------
# GitHub Actions OIDC: CI assumes short-lived roles, no static AWS keys anywhere.
#   plan role  : any PR/branch of this repo, read-only + state read/lock
#   apply-<env>: only workflow runs bound to the matching GitHub Environment
#                (prod's Environment has required reviewers = the manual approval gate)
# ---------------------------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:*"]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name                 = "${var.project}-github-plan"
  description          = "Read-only role for terraform plan on pull requests"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "github_plan_readonly" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    sid       = "StateReadWrite"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    sid       = "StateKms"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role_policy" "github_plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.state_access.json
}

data "aws_iam_policy_document" "apply_trust" {
  for_each = toset(var.environments)
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${each.key}"]
    }
  }
}

resource "aws_iam_role" "github_apply" {
  for_each             = toset(var.environments)
  name                 = "${var.project}-github-apply-${each.key}"
  description          = "terraform apply for ${each.key}; only assumable from the ${each.key} GitHub Environment"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust[each.key].json
  max_session_duration = 3600
}

# The apply role can manage the services this platform uses, and IAM only for gp-* names.
data "aws_iam_policy_document" "apply" {
  #checkov:skip=CKV_AWS_107:Terraform needs to read IAM to plan; writes are scoped below.
  #checkov:skip=CKV_AWS_108:Terraform reads data across these services to diff state.
  #checkov:skip=CKV_AWS_109:Scoped to platform services; IAM writes limited to gp-* resources.
  #checkov:skip=CKV_AWS_110:IAM writes are restricted to gp-* roles/policies.
  #checkov:skip=CKV_AWS_111:Service-level actions are needed by Terraform; resource scoping is per service below.
  #checkov:skip=CKV_AWS_356:Many create APIs do not support resource-level permissions.
  #checkov:skip=CKV2_AWS_40:Service-wide actions are required by Terraform for these services.
  statement {
    sid = "PlatformServices"
    actions = [
      "batch:*", "ec2:*", "ecr:*", "ecs:Describe*", "ecs:List*", "s3:*", "kms:*", "logs:*",
      "lambda:*", "events:*", "dynamodb:*", "sns:*", "sqs:*", "ssm:*", "cloudwatch:*",
      "budgets:*", "cloudtrail:*", "xray:*", "iam:Get*", "iam:List*", "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }
  statement {
    sid = "ScopedIamWrites"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PassRole",
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:TagInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
    ]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/${var.project}-*",
      "arn:${local.partition}:iam::${local.account_id}:instance-profile/${var.project}-*",
      "arn:${local.partition}:iam::${local.account_id}:policy/${var.project}-*",
    ]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"]
  }
}

resource "aws_iam_policy" "apply" {
  name   = "${var.project}-github-apply"
  policy = data.aws_iam_policy_document.apply.json
}

resource "aws_iam_role_policy_attachment" "github_apply" {
  for_each   = aws_iam_role.github_apply
  role       = each.value.name
  policy_arn = aws_iam_policy.apply.arn
}

resource "aws_iam_role_policy" "github_apply_state" {
  for_each = aws_iam_role.github_apply
  name     = "terraform-state"
  role     = each.value.id
  policy   = data.aws_iam_policy_document.state_access.json
}
