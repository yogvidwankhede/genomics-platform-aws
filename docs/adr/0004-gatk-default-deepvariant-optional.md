# ADR-0004: GATK HaplotypeCaller by default, DeepVariant selectable

**Status:** Accepted, 2026-11-22

## Context
Both callers are standard for germline short variants. We measured both on the same GIAB HG001
chr20:10-12 Mb slice (RESULTS.md):

| | SNP F1 | INDEL F1 | Calling step | Peak RSS | Image |
|---|---:|---:|---|---|---|
| GATK 4.7.0.0 | 0.9981 | 0.9802 | 39.6 s, 4 CPU | 0.9 GB | 1.1 GB |
| DeepVariant 1.10.0 | 0.9992 | 0.9876 | 1 m 29 s, 8 CPU | 8 GB | 7.2 GB, x86_64 only |

(Local, under Rosetta emulation; absolute times aren't representative of AWS.)

## Decision
`--caller gatk` is the default; `--caller deepvariant` is a runtime switch with no code change.
The post-calling soft filter is **caller-specific**: GATK `QUAL<30 || FORMAT/DP<5`,
DeepVariant `FORMAT/DP<5` only (DeepVariant already emits PASS/RefCall).

## Why GATK by default
Smaller image, a much lower memory peak (fits smaller, cheaper Spot instances), and it's
familiar to most reviewers. DeepVariant is more accurate here, especially for indels
(+0.0074 F1), so it's the recommendation when accuracy matters more than cost. The default
can flip with a one-line config change once AWS cost per run is measured for both.

## Consequences
- The benchmark itself caught a real bug: a GATK-tuned `QUAL<30` filter cut DeepVariant's
  INDEL recall to 0.516 (602 of 3,536 PASS calls removed). Filters are now chosen per caller,
  and the hap.py step stays in the pipeline as a regression gate.
- nf-test enforces accuracy floors (SNP F1 ≥ 0.95, INDEL F1 ≥ 0.90) on the 100 kb test slice
  so a tool bump can't silently degrade calls.
