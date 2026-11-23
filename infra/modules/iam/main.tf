data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  inputs     = var.bucket_arns["inputs"]
  work       = var.bucket_arns["work"]
  results    = var.bucket_arns["results"]
  log_group  = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${var.batch_log_group_name}"
}

# ---- EC2 instance role (ECS agent, image pulls) ---------------------------------------------
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name}-batch-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "instance_ecs" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid       = "PullPlatformImages"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = var.ecr_repository_arns
  }
  statement {
    sid       = "DecryptImageLayersAndVolumes"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "pull-images"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-batch-instance"
  role = aws_iam_role.instance.name
}

# ---- job roles ------------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# Task role: what every pipeline step container can do. Read inputs, read/write work, write results.
resource "aws_iam_role" "task" {
  name               = "${var.name}-nf-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "task" {
  statement {
    sid       = "ListBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.inputs, local.work, local.results]
  }
  statement {
    sid       = "ReadInputs"
    actions   = ["s3:GetObject"]
    resources = ["${local.inputs}/*"]
  }
  statement {
    sid       = "WorkAndResults"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
    resources = ["${local.work}/*", "${local.results}/*"]
  }
  statement {
    sid       = "UseDataKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "s3-data"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# Head role: the Nextflow driver. Same data access plus the Batch API to orchestrate tasks.
resource "aws_iam_role" "head" {
  name               = "${var.name}-nf-head"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "head" {
  #checkov:skip=CKV_AWS_356:Batch Describe*/List* and RegisterJobDefinition do not support resource-level permissions.
  #checkov:skip=CKV_AWS_111:RegisterJobDefinition does not support resource-level permissions.
  source_policy_documents = [data.aws_iam_policy_document.task.json]

  statement {
    sid = "OrchestrateBatch"
    actions = [
      "batch:DescribeJobQueues", "batch:DescribeComputeEnvironments", "batch:DescribeJobDefinitions",
      "batch:DescribeJobs", "batch:ListJobs", "batch:RegisterJobDefinition",
      "batch:SubmitJob", "batch:TerminateJob", "batch:CancelJob", "batch:TagResource",
      "ecs:DescribeTasks", "ecs:DescribeContainerInstances", "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypes", "ec2:DescribeInstanceAttribute",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "PassTaskRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.task.arn]
  }
  statement {
    sid       = "ReadTaskLogs"
    actions   = ["logs:GetLogEvents", "logs:DescribeLogStreams"]
    resources = [local.log_group, "${local.log_group}:*"]
  }
}

resource "aws_iam_role_policy" "head" {
  name   = "nextflow-driver"
  role   = aws_iam_role.head.id
  policy = data.aws_iam_policy_document.head.json
}
