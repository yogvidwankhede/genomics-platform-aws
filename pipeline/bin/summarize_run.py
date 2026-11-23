#!/usr/bin/env python3
"""Collapse per-sample QC + variant + benchmark outputs into one JSON document.

The platform API serves this file straight from S3, so its shape is a contract:
bump SCHEMA_VERSION on any breaking change.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

SCHEMA_VERSION = 2


def parse_fastp(path: Path) -> dict:
    data = json.loads(path.read_text())
    before = data.get("summary", {}).get("before_filtering", {})
    after = data.get("summary", {}).get("after_filtering", {})
    return {
        "reads_before_filtering": before.get("total_reads"),
        "reads_after_filtering": after.get("total_reads"),
        "q30_rate_after_filtering": after.get("q30_rate"),
        "gc_content_after_filtering": after.get("gc_content"),
        "duplication_rate_fastp": data.get("duplication", {}).get("rate"),
    }


def parse_markdup(path: Path) -> dict:
    """Read the Picard METRICS CLASS table (first data row)."""
    lines = path.read_text().splitlines()
    for i, line in enumerate(lines):
        if line.startswith("## METRICS CLASS"):
            header = lines[i + 1].split("\t")
            values = lines[i + 2].split("\t")
            row = dict(zip(header, values, strict=False))
            return {
                "percent_duplication": _num(row.get("PERCENT_DUPLICATION")),
                "read_pairs_examined": _num(row.get("READ_PAIRS_EXAMINED")),
            }
    return {}


def parse_bcftools_stats(path: Path) -> dict:
    out: dict = {}
    for line in path.read_text().splitlines():
        cols = line.split("\t")
        if cols[0] == "SN" and len(cols) >= 4:
            key = cols[2].rstrip(":").replace("number of ", "").replace(" ", "_")
            if key in {"records", "SNPs", "indels", "MNPs", "multiallelic_sites"}:
                out[key.lower()] = int(cols[3])
        elif cols[0] == "TSTV" and len(cols) >= 5:
            out["ts_tv"] = float(cols[4])
    return out


def parse_happy(path: Path) -> dict:
    """hap.py summary.csv -> {SNP: {...}, INDEL: {...}} for the PASS rows."""
    result: dict = {}
    with path.open() as fh:
        for row in csv.DictReader(fh):
            if row.get("Filter") != "PASS":
                continue
            result[row["Type"]] = {
                "truth_total": _num(row.get("TRUTH.TOTAL")),
                "true_positives": _num(row.get("TRUTH.TP")),
                "false_negatives": _num(row.get("TRUTH.FN")),
                "false_positives": _num(row.get("QUERY.FP")),
                "recall": _num(row.get("METRIC.Recall")),
                "precision": _num(row.get("METRIC.Precision")),
                "f1": _num(row.get("METRIC.F1_Score")),
            }
    return result


def _num(value):
    if value in (None, ""):
        return None
    try:
        f = float(value)
    except ValueError:
        return value
    return int(f) if f.is_integer() and "." not in str(value) else f


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sample", required=True)
    ap.add_argument("--caller", default="gatk")
    ap.add_argument("--individual")
    ap.add_argument("--downsample", type=float, default=1.0)
    ap.add_argument("--seed", type=int, default=100)
    ap.add_argument("--target-bp", type=int, default=0, help="calling-region size, for mean coverage")
    ap.add_argument("--fastp", type=Path, required=True)
    ap.add_argument("--markdup", type=Path, required=True)
    ap.add_argument("--bcftools-stats", type=Path, required=True)
    ap.add_argument("--happy", type=Path)
    ap.add_argument("--pipeline-version", default="unknown")
    ap.add_argument("--run-name", default="unknown")
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args(argv)

    qc = {**parse_fastp(args.fastp), **parse_markdup(args.markdup)}
    bases = json.loads(args.fastp.read_text()).get("summary", {}).get("after_filtering", {}).get("total_bases")
    # Approximate: reads overlapping the window edges add a little, duplicates are included.
    qc["mean_coverage_estimate"] = round(bases / args.target_bp, 2) if bases and args.target_bp else None
    summary = {
        "schema_version": SCHEMA_VERSION,
        "sample": args.sample,
        "caller": args.caller,
        "individual": args.individual or args.sample,
        "downsample": args.downsample,
        "seed": args.seed,
        "run_name": args.run_name,
        "pipeline_version": args.pipeline_version,
        "qc": qc,
        "variants": parse_bcftools_stats(args.bcftools_stats),
        "benchmark": parse_happy(args.happy) if args.happy else None,
    }
    args.output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
