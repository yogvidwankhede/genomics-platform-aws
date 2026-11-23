# ADR-0002: Spot-only compute with scale-to-zero

**Status:** Accepted, 2026-11-22

## Context
Cost cap of about $10 total. Pipeline tasks are idempotent and restartable; Nextflow retries
failed tasks and resumes from cached work.

## Decision
- A single **SPOT** compute environment, `SPOT_PRICE_CAPACITY_OPTIMIZED`, across six instance
  families (m6i, m5, c6i, c5, r6i, r5), so a reclaim in one pool doesn't stall the queue.
- `min_vcpus = desired_vcpus = 0`; `max_vcpus` 16 (dev) / 64 (prod) is the spend ceiling.
- Tasks: Nextflow `aws.batch.maxSpotAttempts = 3`; error strategy retries 130-145/104/175 exits.
- **Head job also on Spot.** The Batch retry strategy retries `Host EC2*` reasons 3 times, and
  `NXF_CLOUDCACHE_PATH` keeps the resume cache in S3, so a retried head job resumes instead of
  recomputing.
- A queue-level `job_state_time_limit_action` cancels jobs stuck RUNNABLE for an hour on
  insufficient capacity, and a watchdog metric alarms after 30 min.

## Alternatives
- **On-demand head + Spot tasks:** the most common production pattern; costs more per run
  and needs a second compute environment. Rejected for the cost cap, but it's a one-line queue
  change if reclaim rates prove painful.
- **Fargate Spot:** see ADR-0001.

## Consequences
- Wall time can grow under reclaim; correctness can't change (Nextflow task hashing).
- The resume-after-head-reclaim behaviour is **designed but not yet observed on AWS**.
