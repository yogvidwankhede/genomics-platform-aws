data "aws_region" "current" {}

# ---- logs -----------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "jobs" {
  #checkov:skip=CKV_AWS_338:Retention is a per-env cost decision (var.log_retention_days); prod can set 365.
  name              = "/${replace(var.name, "-", "/")}/batch"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

# ---- launch template ------------------------------------------------------------------------
# No internet: the AWS CLI that Nextflow mounts into task containers (aws.batch.cliPath) is
# fetched from the artifacts bucket through the S3 gateway endpoint at boot.
locals {
  user_data = <<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="==BOUNDARY=="

    --==BOUNDARY==
    Content-Type: text/x-shellscript; charset="us-ascii"

    #!/bin/bash
    set -euxo pipefail
    curl -fsS --retry 5 -o /tmp/awscli.zip \
      "https://${var.artifacts_bucket}.s3.${data.aws_region.current.region}.amazonaws.com/bootstrap/awscli-exe-linux-x86_64.zip"
    cd /tmp && python3 -m zipfile -e awscli.zip /tmp && chmod -R +x /tmp/aws
    /tmp/aws/install --install-dir /opt/aws-cli --bin-dir /opt/aws-cli/bin
    /opt/aws-cli/bin/aws --version
    rm -rf /tmp/aws /tmp/awscli.zip
    echo ECS_ENABLE_SPOT_INSTANCE_DRAINING=true >> /etc/ecs/ecs.config
    echo ECS_IMAGE_PULL_BEHAVIOR=prefer-cached >> /etc/ecs/ecs.config

    --==BOUNDARY==--
  EOT
}

resource "aws_launch_template" "compute" {
  name_prefix            = "${var.name}-batch-"
  update_default_version = true
  user_data              = base64encode(local.user_data)

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # 1 hop: containers cannot reach IMDS, so tasks only ever get their job-role credentials.
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-batch" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${var.name}-batch" }
  }
}

# ---- compute environment: Spot only, scales to zero -----------------------------------------
resource "aws_batch_compute_environment" "spot" {
  name_prefix = "${var.name}-spot-"
  type        = "MANAGED"
  state       = "ENABLED"

  compute_resources {
    type                = "SPOT"
    allocation_strategy = "SPOT_PRICE_CAPACITY_OPTIMIZED"
    min_vcpus           = 0
    desired_vcpus       = 0
    max_vcpus           = var.max_vcpus
    instance_type       = var.instance_types
    instance_role       = var.instance_profile_arn
    subnets             = var.subnet_ids
    security_group_ids  = var.security_group_ids

    launch_template {
      launch_template_id = aws_launch_template.compute.id
      version            = aws_launch_template.compute.latest_version
    }

    ec2_configuration {
      image_type = "ECS_AL2023"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_batch_job_queue" "this" {
  name     = "${var.name}-spot"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.spot.arn
  }

  job_state_time_limit_action {
    action           = "CANCEL"
    max_time_seconds = 3600
    reason           = "CAPACITY:INSUFFICIENT_INSTANCE_CAPACITY"
    state            = "RUNNABLE"
  }
}

# ---- Nextflow head job ----------------------------------------------------------------------
resource "aws_batch_job_definition" "head" {
  name                  = "${var.name}-nextflow-head"
  type                  = "container"
  platform_capabilities = ["EC2"]
  propagate_tags        = true

  timeout {
    attempt_duration_seconds = var.head_timeout_seconds
  }

  # Spot reclaim of the head job is retried; NXF_CLOUDCACHE_PATH lets the retry -resume.
  retry_strategy {
    attempts = 3
    evaluate_on_exit {
      on_status_reason = "Host EC2*"
      action           = "RETRY"
    }
    evaluate_on_exit {
      on_reason = "*"
      action    = "EXIT"
    }
  }

  container_properties = jsonencode({
    image      = var.head_image
    jobRoleArn = var.head_role_arn
    command    = ["nextflow", "-version"]
    resourceRequirements = [
      { type = "VCPU", value = tostring(var.head_vcpus) },
      { type = "MEMORY", value = tostring(var.head_memory_mib) },
    ]
    environment = [
      { name = "NXF_ANSI_LOG", value = "false" },
      { name = "NXF_OFFLINE", value = "true" },
      { name = "NXF_OPTS", value = "-Xms512m -Xmx1536m" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.jobs.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "head"
      }
    }
    readonlyRootFilesystem = false
    privileged             = false
  })
}
