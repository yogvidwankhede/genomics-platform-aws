# Runbook

Alarm descriptions link to the matching section here. Every command assumes the repo root and
AWS credentials from SSO / `aws configure sso` (never long-lived keys).

- [Deploy](#deploy)
- [Run a pipeline](#run-a-pipeline)
- [Alarm: run failed](#run-failed)
- [Alarm: queue stuck](#queue-stuck)
- [Alarm: Lambda errors](#lambda-errors)
- [Alarm: DLQ not empty](#dlq)
- [Rerun with -resume](#rerun-with-resume)
- [Rotate access](#rotate-access)
- [Rollback](#rollback)
- [Teardown](#teardown)

---

## Deploy

**0. Prerequisites:** Terraform ≥ 1.10, Docker, AWS CLI v2, and an AWS profile with admin on a
sandbox account (bootstrap only; everything after goes through the scoped roles).

**1. Bootstrap (once per account)**

```bash
make bootstrap-plan
```

```bash
make bootstrap-apply
```

```bash
terraform -chdir=infra/bootstrap output
```

Put `state_bucket` into `TF_STATE_BUCKET` (or into `infra/envs/<env>.backend.hcl`), and set the
GitHub variables described in [branch-protection.md](branch-protection.md).

**2. Plan dev and read the cost estimate**

```bash
make plan ENV=dev TF_STATE_BUCKET=<state_bucket>
```

The plan ends with `scripts/cost_estimate.py` output. Expect roughly 8 interface endpoints
(≈ $0.08/h) as the only idle cost in dev.

**3. Apply (explicit confirmation required)**

```bash
make apply ENV=dev CONFIRM=yes
```

**4. Stage what NAT-less instances need**

```bash
make stage-awscli
```

```bash
make mirror-images
```

```bash
make push-head
```

These stage the AWS CLI bundle in the artifacts bucket (instances fetch it via the S3 endpoint),
copy every pinned tool image into ECR `mirror/...`, and build and push `gp/nextflow-head:<version>`.

**5. Smoke test.** `MODE=direct` submits straight to Batch; `MODE=event` exercises the S3 → EventBridge → Lambda path.

```bash
MODE=direct make submit-benchmark ENV=dev
```

```bash
MODE=event make submit-benchmark ENV=dev
```

Record the results in `RESULTS.md` (runtime from `pipeline_info/trace_*.txt`, hap.py from
`benchmark/HG001/*.summary.csv`, cost from Cost Explorer filtered by tag `Project=genomics-platform`
**after** the day's data has landed, usually 24 h).

## Run a pipeline

Upload to the inputs bucket under one prefix. **Upload `samplesheet.csv` last**, because that
object is the trigger.

```
s3://gp-<env>-inputs-<acct>/runs/<run_id>/
  R1.fastq.gz  R2.fastq.gz        # FASTQ paths in the samplesheet are relative to it
  params.json                     # optional: fasta, intervals, truth_vcf, truth_bed, caller ...
  samplesheet.csv                 # sample,fastq_1,fastq_2  <- triggers the run
```

`run_id` must match `^[a-z0-9][a-z0-9-]{2,62}$`. To follow the run:

```bash
awscurl --service lambda "$(terraform -chdir=infra/platform output -raw api_url)runs/<run_id>"
```

You also get the SNS email (if subscribed) and the `gp-<env>-platform` dashboard.

## Run failed

The `gp-<env>-run-failed` alarm fires; SNS carries `run_id`, `reason`, `nextflow_log` and `batch_job_id`.

1. **Read the head log** (copied on exit even on failure):

   ```bash
   aws s3 cp s3://gp-<env>-results-<acct>/runs/<run_id>/logs/nextflow.log - | grep -E 'ERROR|Caused by|exit status' -A5
   ```

2. **Find the failing task.** The log names the process and its work dir
   (`s3://gp-<env>-work-<acct>/runs/<run_id>/work/xx/yyyy`). Get `.command.err`, `.command.log`
   and `.exitcode` from there:

   ```bash
   aws s3 cp s3://.../work/xx/yyyy/.command.err -
   ```

3. **Classify the failure:**

   | Symptom | Likely cause | Action |
   |---|---|---|
   | `statusReason` starts `Host EC2 (instance i-…) terminated` | Spot reclaim | Batch retries the head automatically (3 attempts); tasks retry via `maxSpotAttempts`. Re-submit if all attempts were used ([rerun](#rerun-with-resume)) |
   | exit 137 / `OutOfMemoryError` | memory label too small | the task retries with 2× memory; if it still fails, raise the label in `conf/base.config`, release, rerun with resume |
   | `CannotPullContainerError` | image missing from the ECR mirror | `make mirror-images`, then rerun |
   | `aws: not found` / exit 127 at staging | the instance did not install the CLI | check the artifacts bucket has `bootstrap/awscli-exe-linux-x86_64.zip` (`make stage-awscli`) and the instance user-data log `/var/log/cloud-init-output.log` |
   | nf-schema error at start | bad samplesheet or params | the run never started; fix the input and upload under a **new** run_id |
   | hap.py fails | truth VCF without `.tbi`, or contig names differ | upload `truth.vcf.gz.tbi`; use the same reference build as the truth set |

4. Record the run in DynamoDB (it already shows `FAILED` and `status_reason`) and in the PR
   or issue that fixes it.

## Queue stuck

The `gp-<env>-queue-stuck` alarm means the oldest RUNNABLE job has waited more than 30 min.

1. Check the compute environment:

   ```bash
   aws batch describe-compute-environments --query 'computeEnvironments[].{s:status,r:statusReason,d:computeResources.desiredvCpus}'
   ```

2. `INVALID` usually means the launch template or instance profile changed outside Terraform.
   Re-apply.
3. If desired vCPUs are > 0 but there are no instances, it's Spot capacity: widen
   `instance_types` in `infra/modules/batch` (or add AZs via `az_count`) and apply.
4. Check the job's resource request fits an allowed instance (a 12 GB task can't land on a
   c5.large-only fleet).
5. The queue also cancels jobs that sit RUNNABLE for an hour with
   `CAPACITY:INSUFFICIENT_INSTANCE_CAPACITY` (`job_state_time_limit_action`), so cost can't creep.

## Lambda errors

`gp-<env>-<fn>-errors` alarm.

```bash
aws logs tail /aws/lambda/gp-<env>-<fn> --since 1h --format short --filter-pattern '"level":"ERROR"'
```

Logs are JSON, so filter on `run_id`. Errors from the AWS SDK (throttling) are retried by
EventBridge (4 attempts, 1 h max age) before going to the DLQ.

## DLQ

`gp-<env>-trigger-dlq` alarm: an event could not be delivered or processed after retries.

```bash
aws sqs receive-message --queue-url "$(aws sqs get-queue-url --queue-name gp-<env>-trigger-dlq --query QueueUrl --output text)" --max-number-of-messages 10
```

Fix the cause, then replay. For a lost samplesheet event, re-copy the object onto itself
(`aws s3 cp s3://…/samplesheet.csv s3://…/samplesheet.csv --metadata replay=1`). Submits are
idempotent per run_id, so a replay never starts a duplicate run.

## Rerun with resume

Each run's Nextflow cache lives in S3 (`NXF_CLOUDCACHE_PATH=s3://…-work-…/runs/<run_id>/cache`),
and the head command always passes `-resume`. To rerun a failed run and reuse every completed
task, resubmit **the same run_id** with the operator CLI:

```bash
python3 services/trigger/src/gp_trigger/cli.py submit --env dev --run-id <run_id> \
  --samplesheet s3://gp-dev-inputs-<acct>/runs/<run_id>/samplesheet.csv \
  --params-file params.json --dry-run
```

Drop `--dry-run` to submit. Completed tasks show as `CACHED` in the new trace. Work files
expire after 7 days (lifecycle), so resume only works within that window.

Locally it's the same idea:

```bash
nextflow run pipeline -profile benchmark,docker -resume
```

## Rotate access

- **There are no long-lived keys to rotate.** CI uses OIDC; people use SSO; workloads use roles.
- **Revoke CI immediately:** remove the role's trust on GitHub
  (`aws iam update-assume-role-policy` with an empty `Statement`) or set
  `create_github_oidc_provider=false` and apply bootstrap. Running sessions expire within 1 h
  (`max_session_duration`).
- **Rotate KMS:** automatic yearly rotation is on for both CMKs. For an immediate rotation, use
  `aws kms rotate-key-on-demand --key-id alias/gp-<env>-data`; earlier key material is kept,
  so existing objects stay readable. **Do not** `-replace` the key resource: that creates a
  different key and schedules the old one for deletion, which would orphan everything
  encrypted with it.
- **Rotate a suspected leaked human credential:** disable it in IAM Identity Center, then check
  CloudTrail (`gp-dev-trail`) for activity from that principal.
- **API access:** the function URL is `AWS_IAM`, so access is whatever IAM grants
  `lambda:InvokeFunctionUrl`. Remove the policy to revoke.

## Rollback

| What changed | How to roll back |
|---|---|
| Pipeline / head image | Images are immutable: point `pipeline_version` in tfvars back to the previous tag, `make plan` / `make apply`. New runs use the old image; in-flight runs keep theirs |
| Terraform change | `git revert <merge-commit>` → PR → CI plan shows the inverse diff → merge → `deploy.yml` applies dev, then prod after approval. For an emergency, check out the previous commit locally and `make plan` / `make apply ENV=<env> CONFIRM=yes` |
| Lambda code | same as Terraform (the code hash changes); or `aws lambda update-function-code` with the previous zip as a stop-gap, then fix forward |
| State corruption | the state bucket is versioned: restore the previous `platform/<env>/terraform.tfstate` version with `aws s3api copy-object --copy-source bucket/key?versionId=…`, then `terraform plan` to confirm no drift |
| Bad data in results | buckets are versioned: restore prior object versions; DynamoDB has PITR (35 days) |

## Teardown

```bash
make destroy ENV=dev
```

```bash
make verify-teardown ENV=dev
```

- `make destroy` is one command. Dev buckets and repos have `force_destroy=true`
- `make verify-teardown` should print empty lists for endpoints, instances and buckets

Prod keeps `force_destroy=false` and DynamoDB deletion protection. Empty it deliberately
before destroying.

To remove everything including state, after every environment is destroyed:

```bash
terraform -chdir=infra/bootstrap apply -var force_destroy_state=true
```

```bash
terraform -chdir=infra/bootstrap destroy -var force_destroy_state=true
```

KMS keys enter a 7-day pending-deletion window before they are gone. Check Cost Explorer the
next day to confirm spend has stopped.
