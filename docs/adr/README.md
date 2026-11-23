# Architecture Decision Records

| # | Decision | Status |
|---|---|---|
| [0001](0001-aws-batch-over-fargate-and-eks.md) | Run Nextflow on AWS Batch (EC2), not Fargate or EKS | Accepted |
| [0002](0002-spot-only-compute.md) | Spot-only compute, scale to zero, retry reclaims | Accepted |
| [0003](0003-terraform-state-and-environment-layout.md) | One root module, per-env tfvars + state keys, S3-native locking | Accepted |
| [0004](0004-gatk-default-deepvariant-optional.md) | GATK as default caller, DeepVariant selectable, caller-specific filters | Accepted |
| [0005](0005-nat-less-vpc-with-endpoints.md) | No NAT gateway; VPC endpoints + ECR mirror + offline head image | Accepted |
| [0006](0006-deterministic-alignment-and-pinned-environment.md) | Fixed BWA-MEM2 batch size + pinned images so results are byte-identical across threads and laptop/AWS | Accepted |

Format: context → decision → consequences, with the alternatives considered.
