# Results

Only numbers from runs that actually happened are recorded here. Each row says where it ran.
**Nothing in this file has run on AWS yet.** The AWS section stays empty until a real run
(M3) is executed and its Cost Explorer figures are in.

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
| checkov 3.4.6 | 390 passed, 0 failed, 32 skipped (justified inline) |
| Trivy 0.76.2 on head image (HIGH/CRITICAL, fixable) | 0 after removing the unused Docker CLI; 1 accepted CVE in Nextflow's launcher jar (`.trivyignore`) |
| actionlint 1.7.9 / pre-commit (13 hooks) | clean / all pass |

GitHub Actions results are on the PRs (#5 onward runs `ci.yml`).

## AWS

| Item | Status |
|---|---|
| `terraform plan` / `apply` against a real account | **Not run** |
| Benchmark on AWS Batch (Spot) | **Not run** |
| Event-triggered run (S3 → EventBridge → Lambda → Batch) | **Not run** (handlers tested with moto only) |
| Measured cost per run | **Not measured**. `scripts/cost_estimate.py` gives a pre-apply estimate (≈ $0.49 for 3 h up + 1 run in dev), which is an assumption, not a result |
