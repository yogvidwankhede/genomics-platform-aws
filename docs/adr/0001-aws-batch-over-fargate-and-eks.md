# ADR-0001: AWS Batch on EC2 for pipeline execution

**Status:** Accepted, 2026-11-22

## Context
Germline calling is bursty, batch-shaped work: tens of short containers per sample, some
memory-heavy (MarkDuplicates 3.1 GB, DeepVariant 8 GB peak in the local benchmark), idle most
of the time. The platform team is small, so we want the least to operate, and the cost cap is
about $10 total.

## Options
| | AWS Batch (EC2) | AWS Batch (Fargate) | EKS (+ Karpenter) |
|---|---|---|---|
| Nextflow support | first-class `awsbatch` executor | needs Fusion/Wave for S3 staging | `k8s` executor, needs shared storage (EFS/Fusion) |
| Scale to zero | yes (min vCPU 0) | yes | node groups yes, control plane **$0.10/h always** |
| Spot | EC2 Spot, instance diversity | Fargate Spot | Spot via Karpenter |
| GPU / large memory | any instance type | no GPU, 120 GB max | any |
| Ops burden | managed queue + CE | lowest | cluster upgrades, add-ons, IRSA, CNI |
| Idle cost | $0 compute | $0 | ~$73/month control plane |

## Decision
AWS Batch with a managed **EC2 Spot** compute environment, one job queue, and the Nextflow head
job itself running as a Batch job.

## Consequences
- No always-on control plane; idle compute cost is $0.
- We own the launch template (EBS size, AWS CLI bootstrap, IMDS hardening), which Fargate would hide.
- Instance boot (~2-4 min) is added to wall time; fine for runs measured in minutes to hours.
- Moving to EKS later only touches the executor config plus `infra/modules/batch`. The pipeline is executor-agnostic.
