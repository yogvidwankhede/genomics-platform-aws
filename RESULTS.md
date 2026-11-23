# Results

Only numbers from runs that actually happened are recorded here. Each row says where it ran
(local laptop, GitHub Actions, or AWS). Where something was not measured, it says so.

## Environment for the local runs

| Item | Value |
|---|---|
| Date | 2026-11-22 |
| Host | Apple M4 Max (arm64), macOS 26.6 |
| Container runtime | Colima (vz, Rosetta 2), VM with 8 vCPU / 14 GiB. All tool images are linux/amd64 and run **under Rosetta emulation**, so timings are slower than native x86_64 |
| Nextflow / nf-test | 26.10.7 / 0.9.5 |
| Pipeline | `pipeline/` v0.1.0 at the M1 branch head (`fix(pipeline): use a caller-specific default soft filter`) |
| Tools | bwa-mem2 2.2.1, GATK 4.7.0.0, DeepVariant 1.10.0, bcftools 1.25, fastp 1.4.0, hap.py 0.3.15 (all from the pinned containers in `pipeline/modules/local`) |

## GIAB HG001 benchmark (local, Docker)

**Data** (`scripts/fetch_benchmark_data.sh`):
- Reads: HG001 (NA12878) HiSeq X PCR-free 30x, GRCh38, from the Google Brain Genomics public bucket. The slice is chr20:10,000,000-12,000,000, converted back to paired FASTQ: **250,302 read pairs** (500,604 reads)
- Reference: UCSC hg38 chr20 (the whole chromosome is indexed; calling is restricted to the 2 Mb window)
- Truth: GIAB **NISTv4.2.1** HG001 GRCh38 benchmark VCF and confident regions inside the window: 310 intervals, 1,952,262 bp, 3,163 truth records
- Evaluation: hap.py 0.3.15 (xcmp engine), `--pass-only`, confident regions via `-f`

### Accuracy (hap.py, PASS calls)

| Caller | Type | Truth | TP | FN | FP | Recall | Precision | **F1** |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| GATK HaplotypeCaller 4.7.0.0 | SNP | 2,652 | 2,648 | 4 | 6 | 0.9985 | 0.9977 | **0.9981** |
| GATK HaplotypeCaller 4.7.0.0 | INDEL | 405 | 396 | 9 | 7 | 0.9778 | 0.9826 | **0.9802** |
| DeepVariant 1.10.0 (WGS model) | SNP | 2,652 | 2,649 | 3 | 1 | 0.9989 | 0.9996 | **0.9992** |
| DeepVariant 1.10.0 (WGS model) | INDEL | 405 | 399 | 6 | 4 | 0.9852 | 0.9901 | **0.9876** |

Exact values: `data/runs/benchmark-local-*/benchmark/HG001/HG001.happy.summary.csv`.
Soft filters: GATK `QUAL<30 || FORMAT/DP<5`; DeepVariant `FORMAT/DP<5` on top of its own PASS/RefCall.

**A bug the benchmark caught:** the first DeepVariant run used the GATK-tuned `QUAL<30` filter
and scored INDEL recall **0.516**, SNP recall 0.948. 602 of DeepVariant's 3,536 PASS calls had
QUAL<30 (DeepVariant's QUAL is on a different scale). Making the default filter
caller-specific produced the numbers above. GATK results were unchanged (identical hap.py output).

### QC (identical input for both callers)

| Metric | Value |
|---|---|
| Reads before / after fastp | 500,604 / 487,066 |
| Q30 rate after filtering | 0.8975 |
| Duplicate rate (Picard MarkDuplicates) | 0.1111 |
| PASS variants: GATK | 2,815 SNPs, 701 indels, Ts/Tv 2.17 |
| PASS variants: DeepVariant | 2,821 SNPs, 712 indels, Ts/Tv 2.17 |

### Runtime and resources (Nextflow trace)

| Run | Scope | Wall time | Tasks | Allocated CPU-hours* | Peak RSS (task) |
|---|---|---:|---:|---:|---|
| GATK, cold start (`bench_local_gatk_1`) | full pipeline incl. bwa-mem2 index of chr20 | **1 m 57 s** | 14/14 completed | 0.154 | 3.1 GB (MarkDuplicates) |
| DeepVariant | the `DEEPVARIANT` task only (upstream steps reused from cache) | 1 m 29 s (task) | n/a | n/a | 8 GB (DeepVariant) |

\*Σ(task realtime × requested CPUs) from the trace. This is an upper bound on compute used, not a
cost. A cold end-to-end DeepVariant run was not timed on its own.

## Research benchmark M7 (local, Docker, 2026-11-23)

One Nextflow run (`stoic_wegener`): **28 alignments × 2 callers = 56 call sets, 448 tasks, 0
failed, 1 h 18 m** on the 8-CPU Colima VM; 8.45 allocated CPU-hours. The design, statistics and
interpretation are in [docs/report.md](docs/report.md). Machine-readable outputs are in
[`research/results/`](research/results) (`runs.csv`, `bootstrap_ci.csv`, `titration.csv`,
`paired_mcnemar.csv`, `strata.csv`, `mendelian.csv`, `cost.csv`, `reproducibility.jsonl`,
`alignment_checksums.txt`).

| Result | Value |
|---|---|
| 30x F1 range, 4 samples × 2 callers (block-bootstrap 95% CIs in `bootstrap_ci.csv`) | SNP 0.9961–0.9996; INDEL 0.9802–0.9966 |
| Paired GATK vs DeepVariant at 30x (exact McNemar) | not significant for any sample/type (p 0.125–1.0) |
| Same at 5x and 10x (3 seeds × 2 samples × SNP/INDEL) | significant in every replicate (p ≤ 0.005) |
| Share of SNP errors in GIAB difficult regions (HG001+HG002, 30x) | GATK 16/17, DeepVariant 6/6 |
| Trio Mendelian violations: truth / GATK / DeepVariant | 13 / 16 / 14 sites (caller-attributable: 0 / 3 / 1) |
| Mean allocated CPU-hours per sample: GATK / DeepVariant | 0.100 / 0.202 |
| Reproducibility: repeat, 2 vs 8 threads (`-K` fixed), laptop vs AWS | identical calls; laptop vs AWS byte-identical VCF records |
| Reproducibility without `-K`: 2 vs 8 threads | calls identical, **42 alignment records (22 pairs) differ** |

## Test and quality gates (local)

| Gate | Result |
|---|---|
| `nf-test test` (4 pipeline + 5 module tests, real containers) | 9/9 passed |
| `nextflow lint` | 26 files, 0 errors |
| Stub run (`-profile test -stub`), then `-resume` | 14/14 tasks; 13 cached on resume |
| Head image stub run with `docker run --network none` | completed, so the head job needs no internet |
| `pytest services/trigger` | 31 passed, 87% line coverage |
| `pytest services/api` | 10 passed, 98% line coverage |
| `terraform validate` (2 roots + 7 modules) | 9/9 valid |
| `terraform test` (mocked AWS provider) | 9/9 runs passed (platform dev/prod plans, input validation, Batch, storage) |
| tflint 0.60.0 + AWS ruleset 0.50.0 | 0 issues |
| checkov 3.4.6 (Python 3.13, same as CI) | 464 passed, 0 failed, 50 skipped (each justified inline). The first CI run caught 7 graph-check failures a local Python 3.15 build missed; fixed in #5 |
| Trivy 0.76.2 on head image (HIGH/CRITICAL, fixable) | 0 after removing the unused Docker CLI; 1 accepted CVE in Nextflow's launcher jar (`.trivyignore`) |
| actionlint 1.7.9 / pre-commit (13 hooks) | clean / all pass |

GitHub Actions results are on the PRs (#5 onward runs `ci.yml`).

## AWS (measured, 2026-11-23 UTC)

**Account and environment.** New account on the **AWS Free plan** ($100 credit), `us-east-1`,
`dev` environment (142 Terraform resources). Batch Spot instances were `c7i-flex.large` (head job)
and `m7i-flex.large` (tasks): Free-plan accounts may only launch Free Tier eligible types, so
every task was capped at 2 vCPU / 6 GB. The pipeline was v0.1.4 (head image
`gp/nextflow-head:0.1.4`), with tool images pulled from the ECR mirror through VPC endpoints
(no NAT gateway).

### Benchmark run `hg001-chr20-aws-gatk-3` (GIAB HG001, chr20:10-12 Mb, GATK)

| Metric | Value |
|---|---|
| Tasks | 14/14 completed (`intergalactic_pike`) |
| Nextflow wall time | **11 m 44 s** |
| Head Batch job (DynamoDB `duration_seconds`) | **723.7 s** (03:41:00 → 03:53:03 UTC) |
| Allocated CPU-hours (Σ realtime × vCPU) | 0.096 |
| Σ task realtime vs Σ task duration | 194 s vs 1,612 s: **88% of task wall time was scheduling, instance start-up, image pull and S3 staging** |
| SNP (truth 2,652): TP / FN / FP / recall / precision / **F1** | 2,648 / 4 / 6 / 0.998492 / 0.997740 / **0.998116** |
| INDEL (truth 405): TP / FN / FP / recall / precision / **F1** | 396 / 9 / 7 / 0.977778 / 0.982630 / **0.980198** |

The AWS hap.py summary is **identical** to the local GATK run on the same FASTQs (section above),
despite different CPU counts (2 vs 4–8 per task) and environments.

### Platform behaviour observed on AWS

| Check | Result |
|---|---|
| S3 upload of `samplesheet.csv` → EventBridge → `submit_run` Lambda → DynamoDB + Batch | worked on the first upload (runs 1 and 2) |
| Batch state change → `run_status` Lambda → DynamoDB | recorded FAILED (with reason) and SUCCEEDED, duration, and per-sample F1 |
| Rerun of a failed run with the operator CLI (`attempt` 1→4) | worked after the job-id-scoped status fix |
| **Resume from the S3 task cache** (attempt 4, unchanged inputs) | **14/14 tasks CACHED, 0 submitted; 14.5 s** vs 11 m 44 s cold |
| API (Lambda function URL, `AWS_IAM`) | SigV4-signed `GET /health`, `/runs`, `/runs/{id}`, `/qc`, `/variants`: 200; **unsigned request: 403** |
| Scale to zero between runs | compute environment returned to 0 desired vCPUs |
| Teardown (`make destroy ENV=dev`) | **142 destroyed**; `make verify-teardown`: no VPC endpoints, instances or `gp-dev-*` buckets left |

Nine defects found only on the real account (Free-plan instance limits, Lambda concurrency,
an offline image missing a plugin, a container missing libz, Terraform escaping, resume history,
S3 path handling, and others) are written up in
[`docs/postmortem-first-aws-deployment.md`](docs/postmortem-first-aws-deployment.md).
Raw evidence (DynamoDB scan, Batch job lists, API responses, trace) was saved locally under
`data/runs/aws-hg001-chr20-gatk-3/` (git-ignored).

### Cost

**Not yet measured.** Cost Explorer data lags by about 24 h. The account showed $0.00 of the
$100 credit used when the run started; the dev stack existed from 02:32 to about 04:03 UTC (about 1.5 h; apply start to destroy complete). Until
the actual figure is read from Cost Explorer (filtered by `Project=genomics-platform`), the
only number is the **pre-apply estimate** from `scripts/cost_estimate.py`: about $0.09/h idle
plus about $0.13–0.23 per run. No card charges are possible on the Free plan.
