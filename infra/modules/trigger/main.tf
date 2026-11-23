data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id       = data.aws_caller_identity.current.account_id
  region           = data.aws_region.current.region
  partition        = data.aws_partition.current.partition
  config_parameter = "/${var.name}/pipeline-config"
  # Head jobs are named gp-run-<run_id>; Nextflow's own task jobs are not, so the status
  # rule only sees run-level transitions.
  head_job_prefix = "gp-run-"
}

# ---- run registry ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "runs" {
  name                        = "${var.name}-runs"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "run_id"
  deletion_protection_enabled = var.environment == "prod"

  attribute {
    name = "run_id"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }
  attribute {
    name = "submitted_at"
    type = "S"
  }

  global_secondary_index {
    name            = "by_status"
    projection_type = "ALL"
    key_schema {
      attribute_name = "status"
      key_type       = "HASH"
    }
    key_schema {
      attribute_name = "submitted_at"
      key_type       = "RANGE"
    }
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }
}

# ---- config (SSM, KMS-encrypted) ------------------------------------------------------------
resource "aws_ssm_parameter" "config" {
  name        = local.config_parameter
  description = "Runtime config read by the submit Lambda (no code change to repoint a run)."
  type        = "SecureString"
  key_id      = var.kms_key_arn
  value = jsonencode({
    job_queue      = var.job_queue_name
    job_definition = var.head_job_definition_name
    work_bucket    = var.bucket_names["work"]
    results_bucket = var.bucket_names["results"]
    log_group      = var.batch_log_group_name
    profile        = var.pipeline_profile
    params         = var.pipeline_params
  })
}

# ---- notifications --------------------------------------------------------------------------
resource "aws_sns_topic" "runs" {
  name              = "${var.name}-run-events"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email == null ? 0 : 1
  topic_arn = aws_sns_topic.runs.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-trigger-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = var.kms_key_arn
}

data "aws_iam_policy_document" "dlq" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy    = data.aws_iam_policy_document.dlq.json
}

# ---- Lambda packaging -----------------------------------------------------------------------
data "archive_file" "trigger" {
  type        = "zip"
  source_dir  = var.trigger_source_dir
  output_path = "${path.root}/.build/${var.name}-trigger.zip"
  excludes    = ["**/__pycache__/**"]
}

locals {
  functions = {
    submit_run = {
      description = "S3 samplesheet upload -> register run -> submit Nextflow head job"
      handler     = "gp_trigger.submit_run.handler"
      timeout     = 30
      concurrency = var.submit_concurrency
    }
    run_status = {
      description = "Batch head-job state change -> update run record -> notify"
      handler     = "gp_trigger.run_status.handler"
      timeout     = 30
      concurrency = 5
    }
    queue_watchdog = {
      description = "Emit age of the oldest RUNNABLE job so a stuck queue can alarm"
      handler     = "gp_trigger.queue_watchdog.handler"
      timeout     = 30
      concurrency = 1
    }
  }
  common_env = {
    RUNS_TABLE           = aws_dynamodb_table.runs.name
    CONFIG_PARAMETER     = aws_ssm_parameter.config.name
    TOPIC_ARN            = aws_sns_topic.runs.arn
    JOB_QUEUE            = var.job_queue_name
    INPUTS_BUCKET        = var.bucket_names["inputs"]
    RESULTS_BUCKET       = var.bucket_names["results"]
    ENVIRONMENT          = var.environment
    HEAD_JOB_PREFIX      = local.head_job_prefix
    METRICS_NAMESPACE    = "GenomicsPlatform"
    POWERTOOLS_LOG_LEVEL = "INFO"
  }
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fn" {
  for_each           = merge(local.functions, { api = {} })
  name               = "${var.name}-${replace(each.key, "_", "-")}"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_cloudwatch_log_group" "fn" {
  #checkov:skip=CKV_AWS_338:Retention is a per-env cost decision (var.log_retention_days).
  for_each          = merge(local.functions, { api = {} })
  name              = "/aws/lambda/${var.name}-${replace(each.key, "_", "-")}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

data "aws_iam_policy_document" "fn_base" {
  for_each = merge(local.functions, { api = {} })
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.fn[each.key].arn}:*"]
  }
  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
  statement {
    sid       = "DeadLetter"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
  }
  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }
}

data "aws_iam_policy_document" "submit_run" {
  source_policy_documents = [data.aws_iam_policy_document.fn_base["submit_run"].json]
  statement {
    sid       = "ReadConfig"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.config.arn]
  }
  statement {
    sid       = "ReadSamplesheet"
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arns["inputs"]}/runs/*"]
  }
  statement {
    sid       = "RegisterRun"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.runs.arn]
  }
  statement {
    sid     = "SubmitHeadJob"
    actions = ["batch:SubmitJob", "batch:TagResource"]
    resources = [
      var.job_queue_arn,
      "arn:${local.partition}:batch:${local.region}:${local.account_id}:job-definition/${var.head_job_definition_name}",
      "arn:${local.partition}:batch:${local.region}:${local.account_id}:job-definition/${var.head_job_definition_name}:*",
      "arn:${local.partition}:batch:${local.region}:${local.account_id}:job/*",
    ]
  }
  statement {
    sid       = "Notify"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.runs.arn]
  }
}

data "aws_iam_policy_document" "run_status" {
  source_policy_documents = [data.aws_iam_policy_document.fn_base["run_status"].json]
  statement {
    sid       = "UpdateRun"
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.runs.arn]
  }
  statement {
    sid       = "ReadSummaries"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arns["results"]]
  }
  statement {
    sid       = "ReadSummaryObjects"
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arns["results"]}/runs/*"]
  }
  statement {
    sid       = "Notify"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.runs.arn]
  }
}

data "aws_iam_policy_document" "queue_watchdog" {
  #checkov:skip=CKV_AWS_356:batch:ListJobs does not support resource-level permissions.
  #checkov:skip=CKV_AWS_111:batch:ListJobs does not support resource-level permissions.
  source_policy_documents = [data.aws_iam_policy_document.fn_base["queue_watchdog"].json]
  statement {
    sid       = "ListJobs"
    actions   = ["batch:ListJobs"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "api" {
  source_policy_documents = [data.aws_iam_policy_document.fn_base["api"].json]
  statement {
    sid       = "ReadRuns"
    actions   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
    resources = [aws_dynamodb_table.runs.arn, "${aws_dynamodb_table.runs.arn}/index/*"]
  }
  statement {
    sid       = "ListResults"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arns["results"]]
  }
  statement {
    sid       = "ReadResults"
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arns["results"]}/runs/*"]
  }
}

locals {
  fn_policies = {
    submit_run     = data.aws_iam_policy_document.submit_run.json
    run_status     = data.aws_iam_policy_document.run_status.json
    queue_watchdog = data.aws_iam_policy_document.queue_watchdog.json
    api            = data.aws_iam_policy_document.api.json
  }
}

resource "aws_iam_role_policy" "fn" {
  for_each = local.fn_policies
  name     = "least-privilege"
  role     = aws_iam_role.fn[each.key].id
  policy   = each.value
}

resource "aws_lambda_function" "fn" {
  #checkov:skip=CKV_AWS_117:Functions only call AWS APIs; running them in the NAT-less VPC would need extra endpoints for no isolation gain.
  #checkov:skip=CKV_AWS_272:Code signing is out of scope; artifacts are built in CI from the reviewed commit.
  for_each                       = local.functions
  function_name                  = "${var.name}-${replace(each.key, "_", "-")}"
  description                    = each.value.description
  role                           = aws_iam_role.fn[each.key].arn
  runtime                        = "python3.13"
  architectures                  = ["arm64"]
  handler                        = each.value.handler
  filename                       = data.archive_file.trigger.output_path
  source_code_hash               = data.archive_file.trigger.output_base64sha256
  timeout                        = each.value.timeout
  memory_size                    = 256
  reserved_concurrent_executions = var.reserve_concurrency ? each.value.concurrency : -1
  kms_key_arn                    = var.kms_key_arn

  environment {
    variables = local.common_env
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.fn[each.key].name
  }

  depends_on = [aws_iam_role_policy.fn]
}

resource "aws_lambda_function" "api" {
  #checkov:skip=CKV_AWS_117:Read-only API over DynamoDB/S3; no VPC resources to reach.
  #checkov:skip=CKV_AWS_272:Code signing is out of scope; artifacts are built in CI from the reviewed commit.
  function_name = "${var.name}-api"
  description   = "Read-only REST API: runs, QC metrics, variant summaries"
  role          = aws_iam_role.fn["api"].arn
  runtime       = "python3.13"
  architectures = ["arm64"]
  handler       = "gp_api.lambda_handler.handler"
  filename      = var.api_package_path
  # fileexists() keeps `make destroy` working on a checkout that never built the zip.
  source_code_hash               = fileexists(var.api_package_path) ? filebase64sha256(var.api_package_path) : null
  timeout                        = 15
  memory_size                    = 512
  reserved_concurrent_executions = var.reserve_concurrency ? 5 : -1
  kms_key_arn                    = var.kms_key_arn

  environment {
    variables = {
      RUNS_TABLE     = aws_dynamodb_table.runs.name
      RESULTS_BUCKET = var.bucket_names["results"]
      ENVIRONMENT    = var.environment
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.fn["api"].name
  }

  depends_on = [aws_iam_role_policy.fn]
}

# IAM-authenticated URL: callers sign requests with SigV4 (e.g. `awscurl`), nothing is public.
resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = "AWS_IAM"
}

# ---- event wiring ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "samplesheet_uploaded" {
  name        = "${var.name}-samplesheet-uploaded"
  description = "runs/<run>/samplesheet.csv created in the inputs bucket"
  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [var.bucket_names["inputs"]] }
      object = { key = [{ wildcard = "runs/*/samplesheet.csv" }] }
    }
  })
}

resource "aws_cloudwatch_event_rule" "head_job_state" {
  name        = "${var.name}-head-job-state"
  description = "State changes of Nextflow head jobs on the platform queue"
  event_pattern = jsonencode({
    source        = ["aws.batch"]
    "detail-type" = ["Batch Job State Change"]
    detail = {
      jobQueue = [var.job_queue_arn]
      jobName  = [{ prefix = local.head_job_prefix }]
      status   = ["RUNNING", "SUCCEEDED", "FAILED"]
    }
  })
}

resource "aws_cloudwatch_event_rule" "watchdog" {
  name                = "${var.name}-queue-watchdog"
  description         = "Periodic RUNNABLE-age check"
  schedule_expression = "rate(10 minutes)"
}

locals {
  rule_targets = {
    submit_run     = aws_cloudwatch_event_rule.samplesheet_uploaded
    run_status     = aws_cloudwatch_event_rule.head_job_state
    queue_watchdog = aws_cloudwatch_event_rule.watchdog
  }
}

resource "aws_cloudwatch_event_target" "fn" {
  for_each = local.rule_targets
  rule     = each.value.name
  arn      = aws_lambda_function.fn[each.key].arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 4
  }

  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }
}

resource "aws_lambda_permission" "events" {
  for_each      = local.rule_targets
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = each.value.arn
}
