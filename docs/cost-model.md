# Cost model

All figures are **estimates from us-east-1 list prices** (`scripts/cost_estimate.py`) unless
marked *measured*. No AWS cost has been measured yet (see RESULTS.md).

## What costs money, and when

| Component | Billing | Dev | Notes |
|---|---|---|---|
| Interface endpoints | $0.01/h per endpoint per AZ (+ $0.01/GB) | 8 × 1 AZ = **$0.08/h while deployed** | the main idle cost; destroy when not in use |
| NAT gateway | n/a | $0 | not used (ADR-0005) |
| Batch compute | Spot per second, only while jobs run | $0 idle | `min_vcpus = 0` |
| EBS gp3 100 GB | per instance-hour | ≈ $0.011/instance-h | deleted with the instance |
| KMS CMKs | $1/key/month, prorated | 2 keys ≈ $0.003/h | state + data |
| ECR storage | $0.10/GB-month | ≈ 12 GB mirrored ≈ $0.0016/h | DeepVariant is about 7 GB of that |
| S3 | $0.023/GB-month, tiered | inputs+results < 1 GB per run | work/ expires after 7 days; results → IA (30 d) → Glacier IR (90 d) |
| CloudWatch | alarms $0.10/month each, logs ingest | ≈ 8 alarms | log retention 30 d |
| Lambda, EventBridge, DynamoDB on-demand, SNS, SQS | per request | ≈ $0 at this volume | |
| CloudTrail | first management trail free | $0 | S3 storage only |

## Per benchmark run (estimate)

Locally the GATK benchmark allocated **0.154 CPU-hours** across 14 tasks (*measured*, Nextflow trace).
On Batch the bill is whole instances including boot and the idle scale-down tail, so the
estimator assumes one 8-vCPU Spot instance for 1 h at $0.025/vCPU-h:

```
Spot compute 8 vCPU-h                $0.200
EBS 100 GB for 1 h                   $0.011
S3 (1 GB, 1 month)                   $0.023
= per run                            ≈ $0.23
+ stack idle while deployed          ≈ $0.09/h
```

**3 hours deployed + 1 run ≈ $0.49** (`make cost HOURS=3 RUNS=1`). The $10 budget allows
about 20 such sessions, or about 5 days left up by mistake, and the Budget alarms fire at
50/80/100%.

## Guard-rails
- Spot only; `max_vcpus` 16 in dev; a 4 h head-job timeout; RUNNABLE jobs cancelled after 1 h without capacity.
- AWS Budget $10/month (ACTUAL 50/80/100% and FORECASTED 100%) → SNS and email.
- `make apply` prints the estimate and refuses without `CONFIRM=yes`; `make destroy` is one command;
  `make verify-teardown` lists anything left.
- Mandatory `Project/Environment/Owner/CostCenter` tags on every resource (provider `default_tags`).
  Activate `Project` as a cost-allocation tag in Billing to filter Cost Explorer and the budget
  (`budget_cost_filter_tag`).

## How to measure after a real run
1. Note start and end times; `make destroy` right after.
2. Next day: Cost Explorer → group by Service, filter `Project = genomics-platform`, daily.
3. Record total, Batch/EC2 share and the endpoint share in RESULTS.md with the run_id and trace.
