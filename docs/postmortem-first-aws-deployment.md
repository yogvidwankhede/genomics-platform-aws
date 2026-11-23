# Post-mortem: first deployment to a new AWS account

**Date:** 2026-11-22/23 (UTC) · **Environment:** `dev`, account on the AWS Free plan (new) ·
**Impact:** none to users (first deployment). Every failed attempt cost seconds to minutes of
Spot time, paid from Free-plan credits. · **Format:** blameless.

The platform was built and tested offline first (nf-test, `terraform test` with a mocked
provider, moto, checkov, tflint, Trivy, an offline head-image smoke test). The first real
deployment still surfaced **nine** defects that no offline check could see. Each one below
has its root cause, the fix, and the check that now prevents it from coming back.

| # | Symptom | Root cause | Fix | Guard added |
|---|---|---|---|---|
| 1 | `PutFunctionConcurrency: ... below its minimum value of [10]` on apply | New accounts have a 10-execution Lambda limit; AWS refuses *any* reserved concurrency | `reserve_lambda_concurrency` variable, `false` in dev | env tfvars documents the account limit |
| 2 | `InsufficientS3BucketPolicyException` creating CloudTrail | Trail raced the logs bucket policy (no dependency) | bucket name taken from the *policy* resource (`logs_bucket_with_policy`) | the dependency is now structural, not ordering luck |
| 3 | (pre-empted) Spot launch would fail on CMK-encrypted EBS | EC2's service-linked roles were not allowed to use the data key | key policy: key use via `ec2.<region>` only, this account only | — |
| 4 | Jobs stuck `RUNNABLE`; `Could not launch Spot Instances ... not eligible for Free Tier` | Free-plan accounts may only launch Free Tier eligible types; the new account's Spot and On-Demand quotas read 5 vCPU (a few hours later the Spot quota read 32, apparently raised by AWS after first usage) | dev uses `m7i-flex.large`/`c7i-flex.large`; per-task caps `max_cpus=2`, `max_memory=6.GB` delivered via SSM; `max_vcpus=4` | instance types and caps are environment config, not code |
| 5 | Head job exits in 30 s: `Plugin with id nf-cloudcache not found` | `NXF_CLOUDCACHE_PATH` loads nf-cloudcache implicitly; the head image is offline and didn't bundle it | bake `nf-cloudcache@0.6.2` | CI asserts every required plugin is in the image |
| 6 | hap.py task exit 127: `aws: ... libz.so.1: cannot open shared object file` | Nextflow mounts the host's AWS CLI into task containers; hap.py's minimal biocontainer has no libz | instances bundle the host libz behind a wrapper | `scripts/test_awscli_in_images.sh` runs the mounted CLI inside every pinned image (9/9 OK) |
| 7 | every S3 transfer fails: `argument command: Found invalid choice '10@'` | in the Terraform heredoc the wrapper's `"$$@"` was rendered literally; Terraform only escapes `$${`, so the shell saw `$$` = PID | single `$` | `terraform test` asserts on the **rendered** user-data |
| 8 | rerun with `-resume` recomputed everything | `-resume` needs the previous session id from `.nextflow/history`, which dies with each head container | `gp-run` restores/saves history next to the S3 task cache | resume demonstrated on AWS (see RESULTS.md) |
| 9 | `No such file or directory: /gp-dev-inputs-.../truth.vcf.gz.tbi` | `file("${v}.tbi")` stringified an S3 path to `/bucket/key`, dropping `s3://` | `v.resolveSibling(v.name + '.tbi')` | same code path runs in nf-test locally |

Also found and fixed: the operator CLI and `run_status` could not record a legitimate rerun of
a FAILED run. Reruns now re-register the attempt (new `job_id`, `attempt+1`), and status events
are accepted only from the job on record, so late events from an old attempt still can't
regress a run.

## What went well
- The guard-rails held throughout: Spot only, scale to zero between attempts, the vCPU ceiling,
  every apply behind a reviewed plan, and no account settings changed.
- The event chain (S3 → EventBridge → Lambda → DynamoDB → Batch → EventBridge → Lambda) worked
  on the first try. So did ECR pulls through VPC endpoints with no NAT.
- Triage was fast because the head job writes JSON events to CloudWatch and copies
  `.nextflow.log` to S3 on exit, and the queue/job state is visible via the API and DynamoDB.

## What we'd do differently
- **Test against the rendered artefact, not the source.** Two defects (#6, #7) passed a local
  test that used a hand-written copy of what Terraform generates.
- **Run a "cloud-shaped" smoke test before the benchmark:** one tiny task per container image
  through the real Batch path. That would have surfaced #5–#7 in one cheap run.
- **Probe account limits up front** (Lambda concurrency, EC2 vCPU quotas, Free-plan instance
  eligibility). Done: `make preflight ENV=dev` (read-only, `scripts/preflight.sh`).
