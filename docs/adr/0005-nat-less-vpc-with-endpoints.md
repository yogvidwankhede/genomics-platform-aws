# ADR-0005: No NAT gateway: VPC endpoints, ECR mirror, offline head image

**Status:** Accepted, 2026-11-22

## Context
A NAT gateway is about $0.045/h plus $0.045/GB processed (about $33/month idle), which alone
would exceed the budget, and it widens egress. Batch instances need ECR, S3, CloudWatch Logs,
ECS and STS; the head job also needs the Batch API.

## Decision
- Private subnets with **no internet or NAT gateway**. An **S3 gateway endpoint** (free) and
  8 interface endpoints: `ecr.api`, `ecr.dkr`, `logs`, `ecs`, `ecs-agent`, `ecs-telemetry`,
  `batch`, `sts`. Dev uses 1 AZ (8 ENIs ≈ $0.08/h); prod uses 2.
- Containers can't come from quay.io or Seqera, so every pinned tool image is **mirrored to ECR**
  as `mirror/<original-registry-path>:<original-tag>` (`scripts/mirror_images.sh`). The pipeline
  prefixes `params.container_registry`; locally it's unset and pulls from the public registries.
- The **head image** bakes in the pipeline and plugins and sets `NXF_OFFLINE=true`. This was verified
  locally with `docker run --network none`.
- The AWS CLI that Nextflow mounts into task containers is fetched at boot from an artifacts
  bucket through the S3 endpoint. The bucket policy allows unsigned GETs only for `bootstrap/*`
  and only via this VPC's endpoint (SSE-S3 for that object, since unsigned reads can't use KMS).

## Consequences
- The idle cost is the interface endpoints, so **destroy dev when you're done** (the cost estimator
  warns about this).
- Adding a tool means mirroring its image. CI and the Makefile make that one command.
- No egress means no surprise downloads at runtime: reproducibility improves.
- Not yet exercised on AWS: the user-data CLI bootstrap and `cliPath` mount are the riskiest parts
  of M3 and are called out in the runbook triage table.
