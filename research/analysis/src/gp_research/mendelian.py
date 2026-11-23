"""Truth-free accuracy proxy: Mendelian consistency in a parent-child trio.

At a biallelic autosomal site the child must carry one allele from each parent. Calls that
break this are errors in at least one member. Restricted to regions that are confident in all
three truth sets, so a missing call can be treated as homozygous reference.
"""

from __future__ import annotations

from bisect import bisect_right
from collections.abc import Iterable

Genotypes = dict[tuple[str, int, str, str], tuple[int, int]]


class Regions:
    """Fast point-in-interval lookup for BED intervals."""

    def __init__(self, intervals: Iterable[tuple[str, int, int]]):
        self._by_chrom: dict[str, tuple[list[int], list[int]]] = {}
        for chrom, start, end in sorted(intervals):
            starts, ends = self._by_chrom.setdefault(chrom, ([], []))
            starts.append(start)
            ends.append(end)

    def contains(self, chrom: str, pos1: int) -> bool:
        """pos1 is a 1-based VCF position; BED intervals are 0-based half-open."""
        if chrom not in self._by_chrom:
            return False
        starts, ends = self._by_chrom[chrom]
        i = bisect_right(starts, pos1 - 1) - 1
        return i >= 0 and pos1 - 1 < ends[i]


def intersect(*beds: list[tuple[str, int, int]]) -> list[tuple[str, int, int]]:
    """Intersection of several BED interval lists (each assumed non-overlapping)."""
    result = sorted(beds[0])
    for other in beds[1:]:
        other = sorted(other)
        out, i, j = [], 0, 0
        while i < len(result) and j < len(other):
            (ca, sa, ea), (cb, sb, eb) = result[i], other[j]
            if ca != cb:
                if ca < cb:
                    i += 1
                else:
                    j += 1
                continue
            s, e = max(sa, sb), min(ea, eb)
            if s < e:
                out.append((ca, s, e))
            if ea < eb:
                i += 1
            else:
                j += 1
        result = out
    return result


def is_consistent(child: tuple[int, int], father: tuple[int, int], mother: tuple[int, int]) -> bool:
    c1, c2 = child
    return (c1 in father and c2 in mother) or (c2 in father and c1 in mother)


def mendelian_violations(
    child: Genotypes, father: Genotypes, mother: Genotypes, regions: Regions
) -> dict[str, float | int]:
    """Count sites (non-ref in any member, inside `regions`) violating Mendelian inheritance."""
    sites = {k for g in (child, father, mother) for k in g if regions.contains(k[0], k[1])}
    ref = (0, 0)
    violations = [k for k in sites if not is_consistent(child.get(k, ref), father.get(k, ref), mother.get(k, ref))]
    n = len(sites)
    return {
        "sites": n,
        "violations": len(violations),
        "violation_rate": len(violations) / n if n else float("nan"),
    }
