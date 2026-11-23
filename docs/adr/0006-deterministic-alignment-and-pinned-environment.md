# ADR-0006: Deterministic alignment and a pinned environment for portable validation

**Status:** Accepted, 2026-11-23

## Context
A benchmark run on a laptop is only evidence about production if the cloud run produces the same
calls. Inputs differ between environments in ways that are easy to miss: the number of CPUs per
task (8 locally, 2 on Free-plan AWS instances), the instance types, the executor, and the image
pull path.

## Evidence (docs/report.md §3.6)
| | Calls | Alignments |
|---|---|---|
| Repeat run | identical | identical |
| 8 vs 2 threads, `-K` fixed | identical | identical |
| 8 vs 2 threads, BWA-MEM2 default batching | identical | **42 records / 22 read pairs differ** |
| AWS Batch vs laptop (same FASTQs) | **byte-identical VCF** | n/a |

## Decision
- Pin `bwa-mem2 mem -K 100000000` (`params.bwamem2_batch_bases`). BWA-MEM2's default batch size
  scales with the thread count, and insert-size statistics are estimated per batch, so output
  depends on `-t`.
- Pin every container to an immutable tag (no `latest`), mirror the exact tags into ECR, and bake
  the pipeline and plugins into a versioned head image.
- Treat the reproducibility runs (`make research-repro`) as a release check for any change that
  touches alignment or calling.

## Consequences
- Validated accuracy carries over from development to AWS. This was measured, not assumed.
- `-K` slightly changes batching memory behaviour. Negligible at the tested sizes; revisit for
  whole-genome runs.
- The repro harness costs about 11 minutes on a laptop.
