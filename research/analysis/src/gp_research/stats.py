"""Statistics for variant-calling benchmarks.

* Accuracy metrics from hap.py-style counts (precision, recall, F1).
* Genomic block bootstrap for confidence intervals. Nearby variants are not independent
  (shared reads, repeats, phasing), so resampling single variants understates uncertainty;
  resampling contiguous genomic blocks keeps that correlation inside each draw.
* Exact McNemar test for paired caller comparisons on the same truth variants.

Pure numpy / stdlib so it is easy to audit and unit-test.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass

import numpy as np

TRUTH_CLASSES = ("TP", "FN")
QUERY_CLASSES = ("TP", "FP")


@dataclass(frozen=True)
class Metrics:
    tp_truth: int
    fn: int
    tp_query: int
    fp: int

    @property
    def recall(self) -> float:
        d = self.tp_truth + self.fn
        return self.tp_truth / d if d else float("nan")

    @property
    def precision(self) -> float:
        d = self.tp_query + self.fp
        return self.tp_query / d if d else float("nan")

    @property
    def f1(self) -> float:
        p, r = self.precision, self.recall
        if math.isnan(p) or math.isnan(r) or (p + r) == 0:
            return float("nan")
        return 2 * p * r / (p + r)


def metrics_from_labels(truth_labels: Sequence[str], query_labels: Sequence[str]) -> Metrics:
    """truth_labels: TP/FN per truth variant; query_labels: TP/FP per query variant."""
    t = list(truth_labels)
    q = list(query_labels)
    return Metrics(t.count("TP"), t.count("FN"), q.count("TP"), q.count("FP"))


@dataclass(frozen=True)
class Interval:
    estimate: float
    low: float
    high: float

    def fmt(self, digits: int = 4) -> str:
        return f"{self.estimate:.{digits}f} [{self.low:.{digits}f}, {self.high:.{digits}f}]"


def block_bootstrap(
    truth_pos: Sequence[int],
    truth_labels: Sequence[str],
    query_pos: Sequence[int],
    query_labels: Sequence[str],
    region_start: int,
    region_end: int,
    block_size: int = 50_000,
    n_boot: int = 2000,
    seed: int = 20261122,
    level: float = 0.95,
) -> dict[str, Interval]:
    """Percentile CIs for recall, precision and F1 by resampling genomic blocks.

    Every block of `block_size` bp in [region_start, region_end) is a resampling unit; a draw
    picks n_blocks blocks with replacement and pools their truth and query labels.
    """
    if region_end <= region_start or block_size <= 0:
        raise ValueError("invalid region or block size")
    n_blocks = math.ceil((region_end - region_start) / block_size)

    def per_block(pos: Sequence[int], labels: Sequence[str], classes: tuple[str, str]) -> np.ndarray:
        counts = np.zeros((n_blocks, 2), dtype=np.int64)
        for p, lab in zip(pos, labels, strict=True):
            if lab not in classes or not (region_start <= p < region_end):
                continue
            counts[(p - region_start) // block_size, classes.index(lab)] += 1
        return counts

    tb = per_block(truth_pos, truth_labels, TRUTH_CLASSES)  # [:,0]=TP [:,1]=FN
    qb = per_block(query_pos, query_labels, QUERY_CLASSES)  # [:,0]=TP [:,1]=FP

    point = Metrics(int(tb[:, 0].sum()), int(tb[:, 1].sum()), int(qb[:, 0].sum()), int(qb[:, 1].sum()))
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, n_blocks, size=(n_boot, n_blocks))
    t = tb[idx].sum(axis=1)  # (n_boot, 2)
    q = qb[idx].sum(axis=1)
    with np.errstate(divide="ignore", invalid="ignore"):
        recall = t[:, 0] / (t[:, 0] + t[:, 1])
        precision = q[:, 0] / (q[:, 0] + q[:, 1])
        f1 = 2 * precision * recall / (precision + recall)
    alpha = (1 - level) / 2

    def ci(values: np.ndarray, est: float) -> Interval:
        v = values[~np.isnan(values)]
        if v.size == 0:
            return Interval(est, float("nan"), float("nan"))
        lo, hi = np.quantile(v, [alpha, 1 - alpha])
        return Interval(est, float(lo), float(hi))

    return {
        "recall": ci(recall, point.recall),
        "precision": ci(precision, point.precision),
        "f1": ci(f1, point.f1),
    }


def mcnemar_exact(b: int, c: int) -> float:
    """Two-sided exact McNemar p-value for discordant counts b and c.

    b = pairs where method A is right and B wrong; c = the reverse. Under H0 the discordant
    pairs split 50/50, so p = 2 * P(X <= min(b, c)), X ~ Binomial(b + c, 0.5), capped at 1.
    """
    if b < 0 or c < 0:
        raise ValueError("counts must be non-negative")
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2**n
    return min(1.0, 2 * tail)


def paired_truth_comparison(a: dict[tuple, str], b: dict[tuple, str]) -> dict[str, float | int]:
    """Compare two callers on the same truth variants (keys = variant id, values TP/FN).

    Returns concordant/discordant counts, the McNemar p-value and the recall difference.
    """
    keys = sorted(set(a) & set(b))
    both = only_a = only_b = neither = 0
    for k in keys:
        ra, rb = a[k] == "TP", b[k] == "TP"
        if ra and rb:
            both += 1
        elif ra:
            only_a += 1
        elif rb:
            only_b += 1
        else:
            neither += 1
    n = len(keys)
    return {
        "n_truth": n,
        "both_found": both,
        "only_a": only_a,
        "only_b": only_b,
        "neither": neither,
        "recall_a": (both + only_a) / n if n else float("nan"),
        "recall_b": (both + only_b) / n if n else float("nan"),
        "p_mcnemar": mcnemar_exact(only_a, only_b),
    }
