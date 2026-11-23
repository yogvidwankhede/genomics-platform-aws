"""Readers for pipeline outputs: hap.py annotated VCFs, hap.py extended CSVs, run summaries,
Nextflow traces, and per-sample call VCFs (for Mendelian checks)."""

from __future__ import annotations

import csv
import gzip
import json
import re
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class HappyRecord:
    chrom: str
    pos: int
    ref: str
    alt: str
    side: str  # "TRUTH" or "QUERY"
    label: str  # TP / FN / FP / N / UNK
    vtype: str  # SNP / INDEL / NOCALL


def read_happy_vcf(path: Path) -> Iterator[HappyRecord]:
    """Yield TRUTH and QUERY classifications from a hap.py output VCF (FORMAT BD/BVT)."""
    with gzip.open(path, "rt") as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            f = line.rstrip("\n").split("\t")
            fmt = f[8].split(":")
            for side, col in (("TRUTH", f[9]), ("QUERY", f[10])):
                vals = dict(zip(fmt, col.split(":"), strict=False))
                bd = vals.get("BD", ".")
                if bd in (".", "N"):
                    continue
                yield HappyRecord(f[0], int(f[1]), f[3], f[4], side, bd, vals.get("BVT", "."))


def read_happy_extended(path: Path) -> list[dict]:
    """hap.py extended.csv rows (all subsets/strata), PASS filter only."""
    rows = []
    with open(path) as fh:
        for r in csv.DictReader(fh):
            if r.get("Filter") != "PASS":
                continue
            rows.append(r)
    return rows


def read_summaries(results_dir: Path) -> list[dict]:
    return [json.loads(p.read_text()) for p in sorted(results_dir.glob("summary/*.run_summary.json"))]


def _seconds(text: str) -> float:
    if not text or text == "-":
        return 0.0
    units = {"ms": 0.001, "s": 1, "m": 60, "h": 3600, "d": 86400}
    return sum(float(v) * units[u] for v, u in re.findall(r"([\d.]+)(ms|s|m|h|d)", text))


def read_trace(results_dir: Path) -> list[dict]:
    """All Nextflow trace rows with realtime in seconds and cpus as int (latest trace file wins
    when the same task hash appears twice, e.g. after -resume)."""
    rows: dict[str, dict] = {}
    for p in sorted(results_dir.glob("pipeline_info/trace_*.txt")):
        with open(p) as fh:
            for r in csv.DictReader(fh, delimiter="\t"):
                r["realtime_s"] = _seconds(r.get("realtime", ""))
                r["cpus"] = int(r.get("cpus") or 0)
                rows[r["hash"]] = r
    return list(rows.values())


def read_genotypes(path: Path, pass_only: bool = True) -> dict[tuple[str, int, str, str], tuple[int, int]]:
    """Biallelic genotypes of the first sample: (chrom, pos, ref, alt) -> allele pair (0/1)."""
    out: dict[tuple[str, int, str, str], tuple[int, int]] = {}
    opener = gzip.open if str(path).endswith(".gz") else open
    with opener(path, "rt") as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            f = line.rstrip("\n").split("\t")
            if pass_only and f[6] not in ("PASS", "."):
                continue
            alts = f[4].split(",")
            gt = dict(zip(f[8].split(":"), f[9].split(":"), strict=False)).get("GT", "./.")
            alleles = re.split(r"[/|]", gt)
            if "." in alleles or len(alleles) != 2:
                continue
            for ai, alt in enumerate(alts, start=1):
                pair = tuple(sorted(1 if int(a) == ai else 0 for a in alleles))
                if pair != (0, 0):
                    out[(f[0], int(f[1]), f[3], alt)] = pair
    return out


def read_bed(path: Path) -> list[tuple[str, int, int]]:
    with open(path) as fh:
        return [(c, int(s), int(e)) for c, s, e, *_ in (line.split("\t") for line in fh if line.strip())]
