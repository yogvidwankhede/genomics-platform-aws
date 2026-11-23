data "aws_caller_identity" "current" {}

locals {
  name     = "${var.project}-${var.environment}"
  registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  tags = {
    Project     = "genomics-platform"
    Environment = var.environment
    Owner       = var.owner
    CostCenter  = var.cost_center
    ManagedBy   = "terraform"
    Repository  = "github.com/yogvidwankhede/genomics-platform-aws"
  }
  head_repository = "${var.project}/nextflow-head"
  repositories    = concat([local.head_repository], [for img in var.mirrored_images : "mirror/${img}"])
}

module "storage" {
  source        = "../modules/storage"
  name          = local.name
  force_destroy = var.force_destroy
  s3_vpce_id    = module.network.s3_endpoint_id
}

module "network" {
  source      = "../modules/network"
  name        = local.name
  az_count    = var.az_count
  kms_key_arn = module.storage.kms_key_arn
}

module "ecr" {
  source       = "../modules/ecr"
  repositories = local.repositories
  kms_key_arn  = module.storage.kms_key_arn
  force_delete = var.force_destroy
}

module "iam" {
  source               = "../modules/iam"
  name                 = local.name
  bucket_arns          = module.storage.bucket_arns
  kms_key_arn          = module.storage.kms_key_arn
  ecr_repository_arns  = module.ecr.repository_arns
  batch_log_group_name = "/${replace(local.name, "-", "/")}/batch"
}

module "batch" {
  source               = "../modules/batch"
  name                 = local.name
  subnet_ids           = module.network.private_subnet_ids
  security_group_ids   = [module.network.compute_security_group_id]
  instance_profile_arn = module.iam.instance_profile_arn
  max_vcpus            = var.max_vcpus
  kms_key_arn          = module.storage.kms_key_arn
  artifacts_bucket     = module.storage.bucket_names["artifacts"]
  head_image           = "${local.registry}/${local.head_repository}:${var.pipeline_version}"
  head_role_arn        = module.iam.head_role_arn
}

module "trigger" {
  source                   = "../modules/trigger"
  name                     = local.name
  environment              = var.environment
  kms_key_arn              = module.storage.kms_key_arn
  bucket_names             = module.storage.bucket_names
  bucket_arns              = module.storage.bucket_arns
  job_queue_arn            = module.batch.job_queue_arn
  job_queue_name           = module.batch.job_queue_name
  head_job_definition_name = module.batch.head_job_definition_name
  batch_log_group_name     = module.batch.log_group_name
  trigger_source_dir       = var.trigger_source_dir
  api_package_path         = var.api_package_path
  notification_email       = var.notification_email
  reserve_concurrency      = var.reserve_lambda_concurrency
  pipeline_params = merge(
    {
      container_registry = "${local.registry}/mirror/"
      task_role_arn      = module.iam.task_role_arn
      aws_region         = var.region
    },
    var.pipeline_params,
  )
}

module "observability" {
  source               = "../modules/observability"
  name                 = local.name
  environment          = var.environment
  kms_key_arn          = module.storage.kms_key_arn
  alarm_topic_arn      = module.trigger.topic_arn
  function_names       = module.trigger.function_names
  dlq_name             = module.trigger.dlq_name
  job_queue_name       = module.batch.job_queue_name
  batch_log_group_name = module.batch.log_group_name
  monthly_budget_usd   = var.monthly_budget_usd
  budget_emails        = var.notification_email == null ? [] : [var.notification_email]
  enable_cloudtrail    = var.enable_cloudtrail
  # Taken from the bucket *policy* resource so the trail is only created once CloudTrail's
  # write permission exists (otherwise: InsufficientS3BucketPolicyException on first apply).
  logs_bucket = module.storage.logs_bucket_with_policy
}
