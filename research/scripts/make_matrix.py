#!/usr/bin/env python3
"""Write the experiment-matrix samplesheet for the M7 benchmark.

Design (pre-registered here, before any results are seen):
  * HG001 and HG002: full 30x + downsampled to 1/6, 1/3, 1/2, 2/3 (~5x, 10x, 15x, 20x),
    3 independent seeds per fraction -> 13 rows per sample.
  * HG003 and HG004 (HG002's parents): full 30x only, for the trio Mendelian analysis.
Paths are relative to the samplesheet, which lives in the data directory.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

FRACTIONS = [(1 / 6, "5x"), (1 / 3, "10x"), (1 / 2, "15x"), (2 / 3, "20x")]
SEEDS = [11, 22, 33]


def rows() -> list[dict]:
    out = []

    def row(sample: str, individual: str, frac: float, seed: int) -> dict:
        return {
            "sample": sample,
            "individual": individual,
            "fastq_1": f"reads/{individual}_R1.fastq.gz",
            "fastq_2": f"reads/{individual}_R2.fastq.gz",
            "truth_vcf": f"truth/{individual}.vcf.gz",
            "truth_bed": f"truth/{individual}.bed",
            "downsample": f"{frac:.6f}".rstrip("0").rstrip(".") if frac < 1 else "1",
            "seed": str(seed),
        }

    for ind in ("HG001", "HG002"):
        out.append(row(f"{ind}_30x", ind, 1.0, 100))
        for frac, label in FRACTIONS:
            for seed in SEEDS:
                out.append(row(f"{ind}_{label}_s{seed}", ind, frac, seed))
    for ind in ("HG003", "HG004"):
        out.append(row(f"{ind}_30x", ind, 1.0, 100))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=Path("data/research/samplesheet_matrix.csv"))
    args = ap.parse_args()
    data = rows()
    with args.out.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(data[0]))
        w.writeheader()
        w.writerows(data)
    print(f"wrote {len(data)} rows -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
