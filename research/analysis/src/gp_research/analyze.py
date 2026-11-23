"""Build every table and figure of the M7 report from pipeline outputs.

    python -m gp_research.analyze matrix --results data/runs/research-matrix \
        --data data/research --out research/results --figures docs/figures
    python -m gp_research.analyze compare-vcf A.vcf.gz B.vcf.gz --label local_vs_aws

Nothing here re-runs tools: inputs are run_summary.json, hap.py outputs, filtered VCFs and the
Nextflow trace, so the numbers in the report trace back to files on disk.
"""

from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

from gp_research.io import (  # noqa: E402
    read_bed,
    read_genotypes,
    read_happy_extended,
    read_happy_vcf,
    read_summaries,
    read_trace,
)
from gp_research.mendelian import Regions, intersect, mendelian_violations  # noqa: E402
from gp_research.stats import block_bootstrap, paired_truth_comparison  # noqa: E402

CALLER_LABEL = {"gatk": "GATK HaplotypeCaller", "deepvariant": "DeepVariant"}
CALLER_COLOR = {"gatk": "#1f6feb", "deepvariant": "#d1495b"}
NOMINAL_DEPTH = {1.0: 30, 0.666667: 20, 0.5: 15, 0.333333: 10, 0.166667: 5}
STRATA_ORDER = [
    "notinalldifficult",
    "alldifficult",
    "tandemrepeats_homopolymers",
    "homopolymers_ge7",
    "lowmappability",
    "segdups",
    "gc_extreme",
    "coding",
]


def nominal_depth(frac: float) -> int:
    return min(NOMINAL_DEPTH.items(), key=lambda kv: abs(kv[0] - frac))[1]


# ------------------------------------------------------------------------------------------
# per-run table
# ------------------------------------------------------------------------------------------
def runs_table(results: Path) -> pd.DataFrame:
    rows = []
    for s in read_summaries(results):
        bench = s.get("benchmark") or {}
        for vtype in ("SNP", "INDEL"):
            b = bench.get(vtype, {})
            rows.append(
                {
                    "sample": s["sample"],
                    "individual": s["individual"],
                    "caller": s["caller"],
                    "downsample": float(s["downsample"]),
                    "depth": nominal_depth(float(s["downsample"])),
                    "seed": s["seed"],
                    "coverage_est": s["qc"].get("mean_coverage_estimate"),
                    "type": vtype,
                    "truth_total": b.get("truth_total"),
                    "tp": b.get("true_positives"),
                    "fn": b.get("false_negatives"),
                    "fp": b.get("false_positives"),
                    "recall": b.get("recall"),
                    "precision": b.get("precision"),
                    "f1": b.get("f1"),
                }
            )
    return pd.DataFrame(rows)


# ------------------------------------------------------------------------------------------
# bootstrap CIs + paired tests (from hap.py annotated VCFs)
# ------------------------------------------------------------------------------------------
def happy_labels(vcf: Path, vtype: str):
    truth_pos, truth_lab, query_pos, query_lab, truth_map = [], [], [], [], {}
    for r in read_happy_vcf(vcf):
        if r.vtype != vtype:
            continue
        if r.side == "TRUTH" and r.label in ("TP", "FN"):
            truth_pos.append(r.pos)
            truth_lab.append(r.label)
            truth_map[(r.chrom, r.pos, r.ref, r.alt)] = r.label
        elif r.side == "QUERY" and r.label in ("TP", "FP"):
            query_pos.append(r.pos)
            query_lab.append(r.label)
    return truth_pos, truth_lab, query_pos, query_lab, truth_map


def bootstrap_table(results: Path, region: tuple[str, int, int], samples: list[str]) -> pd.DataFrame:
    _, start, end = region
    rows = []
    for sample in samples:
        for caller in ("gatk", "deepvariant"):
            vcf = results / "benchmark" / f"{sample}.{caller}" / f"{sample}.{caller}.happy.vcf.gz"
            if not vcf.exists():
                continue
            for vtype in ("SNP", "INDEL"):
                tp, tl, qp, ql, _ = happy_labels(vcf, vtype)
                ci = block_bootstrap(tp, tl, qp, ql, start, end, block_size=50_000, n_boot=2000)
                rows.append(
                    {
                        "sample": sample,
                        "caller": caller,
                        "type": vtype,
                        **{f"{m}": ci[m].estimate for m in ("recall", "precision", "f1")},
                        **{f"{m}_lo": ci[m].low for m in ("recall", "precision", "f1")},
                        **{f"{m}_hi": ci[m].high for m in ("recall", "precision", "f1")},
                    }
                )
    return pd.DataFrame(rows)


def paired_table(results: Path, samples: list[str]) -> pd.DataFrame:
    rows = []
    for sample in samples:
        a = results / "benchmark" / f"{sample}.gatk" / f"{sample}.gatk.happy.vcf.gz"
        b = results / "benchmark" / f"{sample}.deepvariant" / f"{sample}.deepvariant.happy.vcf.gz"
        if not (a.exists() and b.exists()):
            continue
        for vtype in ("SNP", "INDEL"):
            ta = happy_labels(a, vtype)[4]
            tb = happy_labels(b, vtype)[4]
            out = paired_truth_comparison(ta, tb)
            rows.append({"sample": sample, "type": vtype, **out})
    return pd.DataFrame(rows).rename(
        columns={
            "only_a": "only_gatk",
            "only_b": "only_deepvariant",
            "recall_a": "recall_gatk",
            "recall_b": "recall_deepvariant",
        }
    )


# ------------------------------------------------------------------------------------------
# stratified accuracy (hap.py extended.csv)
# ------------------------------------------------------------------------------------------
def strata_table(results: Path, samples: list[str]) -> pd.DataFrame:
    rows = []
    for sample in samples:
        for caller in ("gatk", "deepvariant"):
            ext = results / "benchmark" / f"{sample}.{caller}" / f"{sample}.{caller}.happy.extended.csv"
            if not ext.exists():
                continue
            for r in read_happy_extended(ext):
                if r["Subtype"] != "*" or r["Subset"] not in STRATA_ORDER:
                    continue

                def num(k: str, r: dict = r) -> float:
                    v = r.get(k, "")
                    return float(v) if v not in ("", ".") else math.nan

                rows.append(
                    {
                        "sample": sample,
                        "caller": caller,
                        "type": r["Type"],
                        "stratum": r["Subset"],
                        "truth_total": num("TRUTH.TOTAL"),
                        "tp": num("TRUTH.TP"),
                        "fn": num("TRUTH.FN"),
                        "fp": num("QUERY.FP"),
                        "recall": num("METRIC.Recall"),
                        "precision": num("METRIC.Precision"),
                        "f1": num("METRIC.F1_Score"),
                    }
                )
    return pd.DataFrame(rows)


# ------------------------------------------------------------------------------------------
# trio Mendelian consistency
# ------------------------------------------------------------------------------------------
def mendelian_table(results: Path, data: Path) -> pd.DataFrame:
    trio = {"child": "HG002", "father": "HG003", "mother": "HG004"}
    if not all((data / "truth" / f"{s}.bed").exists() for s in trio.values()):
        return pd.DataFrame()
    # GIAB VCFs are not trimmed/left-aligned identically across samples (the same indel can be
    # AAAAT>A in one and AAAATAAA>AAAAT in another), so compare bcftools-normalised truth sets,
    # exactly like the pipeline normalises its calls. Raw truth gave a spurious 1% violation rate.
    truth_dir = data / "truth_norm" if (data / "truth_norm").is_dir() else data / "truth"
    regions = Regions(intersect(*(read_bed(data / "truth" / f"{s}.bed") for s in trio.values())))
    rows = []
    # baseline: the GIAB truth sets themselves (should be ~0 by construction)
    g = {role: read_genotypes(truth_dir / f"{s}.vcf.gz", pass_only=False) for role, s in trio.items()}
    label = "GIAB v4.2.1 truth (normalised)" if truth_dir.name == "truth_norm" else "GIAB v4.2.1 truth (raw)"
    truth = mendelian_violations(g["child"], g["father"], g["mother"], regions)
    truth_sites = truth.pop("violating_sites")
    rows.append({"callset": label, **truth, "shared_with_truth": len(truth_sites), "caller_only": 0})
    for caller in ("gatk", "deepvariant"):
        paths = {
            role: results / "variants" / f"{s}_30x.{caller}" / f"{s}_30x.{caller}.filtered.vcf.gz"
            for role, s in trio.items()
        }
        if not all(p.exists() for p in paths.values()):
            continue
        g = {role: read_genotypes(p) for role, p in paths.items()}
        res = mendelian_violations(g["child"], g["father"], g["mother"], regions)
        sites = res.pop("violating_sites")
        # Violations also present in the independent truth sets reflect the samples (e.g. cell-line
        # variants), not the caller; the caller-attributable error is what remains.
        rows.append(
            {
                "callset": CALLER_LABEL[caller],
                **res,
                "shared_with_truth": len(sites & truth_sites),
                "caller_only": len(sites - truth_sites),
            }
        )
    return pd.DataFrame(rows)


# ------------------------------------------------------------------------------------------
# compute cost per run (Nextflow trace)
# ------------------------------------------------------------------------------------------
def cost_table(results: Path) -> pd.DataFrame:
    shared = defaultdict(float)  # per sample row: seqtk + fastp + bwa + markdup
    caller_specific = defaultdict(float)  # per sample.caller: calling + norm/filter/stats + hap.py
    for t in read_trace(results):
        if t.get("status") not in ("COMPLETED", "CACHED"):
            continue
        tag = t.get("tag") or ""
        cpu_s = t["realtime_s"] * t["cpus"]
        if tag.endswith((".gatk", ".deepvariant")):
            caller_specific[tag] += cpu_s
        elif tag and not tag.startswith("chr"):
            shared[tag] += cpu_s
    rows = []
    for key, cs in caller_specific.items():
        sample, caller = key.rsplit(".", 1)
        rows.append({"sample": sample, "caller": caller, "cpu_hours": (cs + shared.get(sample, 0.0)) / 3600})
    return pd.DataFrame(rows)


# ------------------------------------------------------------------------------------------
# reproducibility
# ------------------------------------------------------------------------------------------
def compare_vcfs(a: Path, b: Path) -> dict[str, int]:
    ga, gb = read_genotypes(a), read_genotypes(b)
    shared = set(ga) & set(gb)
    same_gt = sum(1 for k in shared if ga[k] == gb[k])
    return {
        "records_a": len(ga),
        "records_b": len(gb),
        "shared_sites": len(shared),
        "identical_genotypes": same_gt,
        "only_a": len(set(ga) - set(gb)),
        "only_b": len(set(gb) - set(ga)),
        "identical": int(ga == gb),
    }


# ------------------------------------------------------------------------------------------
# figures
# ------------------------------------------------------------------------------------------
def fig_titration(runs: pd.DataFrame, out: Path) -> None:
    fig, axes = plt.subplots(2, 2, figsize=(10, 7), sharex=True)
    for col, ind in enumerate(sorted(runs["individual"].unique())[:2]):
        for row, vtype in enumerate(("SNP", "INDEL")):
            ax = axes[row][col]
            sub = runs[(runs.individual == ind) & (runs.type == vtype)]
            for caller in ("gatk", "deepvariant"):
                d = sub[sub.caller == caller]
                if d.empty:
                    continue
                g = d.groupby("depth")["f1"].agg(["mean", "std", "count"]).reset_index()
                ax.errorbar(
                    g["depth"],
                    g["mean"],
                    yerr=g["std"].fillna(0),
                    marker="o",
                    capsize=3,
                    color=CALLER_COLOR[caller],
                    label=CALLER_LABEL[caller],
                )
                ax.scatter(d["depth"], d["f1"], s=10, alpha=0.35, color=CALLER_COLOR[caller])
            ax.set_title(f"{ind} {vtype}")
            ax.set_ylabel("F1")
            ax.grid(alpha=0.3)
            if row == 1:
                ax.set_xlabel("nominal coverage (x)")
    axes[0][0].legend(loc="lower right", fontsize=8)
    fig.suptitle("Accuracy vs coverage (GIAB v4.2.1, chr20:10-12 Mb; mean ± SD over 3 seeds)")
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


MIN_STRATUM_N = 20


def fig_strata(strata: pd.DataFrame, out: Path) -> None:
    """F1 per stratum, pooled over HG001+HG002 at 30x. Bars carry the truth count; strata with
    fewer than MIN_STRATUM_N truth variants are greyed out (too few to interpret)."""
    fig, axes = plt.subplots(1, 2, figsize=(13, 5), sharey=True)
    for ax, vtype in zip(axes, ("SNP", "INDEL"), strict=True):
        d = strata[strata.type == vtype].groupby(["stratum", "caller"])[["truth_total", "tp", "fn", "fp"]].sum()
        d = d.reset_index()
        d["recall"] = d.tp / (d.tp + d.fn)
        d["precision"] = d.tp / (d.tp + d.fp)
        d["f1"] = 2 * d.recall * d.precision / (d.recall + d.precision)
        order = [s for s in STRATA_ORDER if s in set(d.stratum)]
        for xi, stratum in enumerate(order):
            n = int(d[d.stratum == stratum].truth_total.max())
            small = n < MIN_STRATUM_N
            for i, caller in enumerate(("gatk", "deepvariant")):
                row = d[(d.stratum == stratum) & (d.caller == caller)]
                val = float(row.f1.iloc[0]) if not row.empty and n > 0 else math.nan
                ax.bar(
                    xi + (i - 0.5) * 0.4,
                    0 if math.isnan(val) else val,
                    width=0.4,
                    color="#bbbbbb" if small else CALLER_COLOR[caller],
                    label=CALLER_LABEL[caller] if xi == 0 else None,
                )
            ax.text(xi, 1.03, f"n={n}" + ("\n(n<20)" if small else ""), ha="center", fontsize=7)
        ax.set_xticks(range(len(order)))
        ax.set_xticklabels(order, rotation=35, ha="right", fontsize=8)
        ax.set_title(f"{vtype}: F1 by GIAB v3.6 stratum (HG001+HG002, 30x)", fontsize=10)
        ax.set_ylim(0, 1.12)
        ax.grid(axis="y", alpha=0.3)
    axes[0].set_ylabel("F1")
    axes[0].legend(fontsize=8, loc="lower left")
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def fig_cost(runs: pd.DataFrame, cost: pd.DataFrame, out: Path) -> None:
    d = runs[runs.type == "INDEL"].merge(cost, on=["sample", "caller"])
    fig, ax = plt.subplots(figsize=(7, 4.8))
    for caller in ("gatk", "deepvariant"):
        c = d[d.caller == caller]
        ax.scatter(c.cpu_hours, c.f1, s=c.depth * 6, color=CALLER_COLOR[caller], label=CALLER_LABEL[caller], alpha=0.7)
    for depth in (5, 10, 15, 20, 30):
        ax.scatter([], [], s=depth * 6, color="#888888", alpha=0.5, label=f"{depth}x")
    ax.set_xlabel("allocated CPU-hours per sample (Nextflow trace, local Docker)")
    ax.set_ylabel("INDEL F1")
    ax.set_title("Compute vs INDEL accuracy (marker size = nominal coverage)")
    ax.grid(alpha=0.3)
    ax.legend(fontsize=7, ncol=2, loc="lower right")
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


# ------------------------------------------------------------------------------------------
def md_table(df: pd.DataFrame, floatfmt: str = ".4f") -> str:
    def fmt(v):
        if isinstance(v, float):
            return "" if math.isnan(v) else format(v, floatfmt)
        return str(v)

    head = "| " + " | ".join(df.columns) + " |\n|" + "|".join("---" for _ in df.columns) + "|\n"
    return head + "".join("| " + " | ".join(fmt(v) for v in row) + " |\n" for row in df.itertuples(index=False))


def run_matrix(results: Path, data: Path, out: Path, figures: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    figures.mkdir(parents=True, exist_ok=True)
    region = read_bed(data / "calling_region.bed")[0]

    runs = runs_table(results)
    runs.to_csv(out / "runs.csv", index=False)
    full = sorted(runs[(runs.depth == 30)]["sample"].unique())

    boot = bootstrap_table(results, region, full)
    boot.to_csv(out / "bootstrap_ci.csv", index=False)
    paired = paired_table(results, sorted(runs["sample"].unique()))
    paired.to_csv(out / "paired_mcnemar.csv", index=False)
    strata = strata_table(results, [s for s in full if s.startswith(("HG001", "HG002"))])
    strata.to_csv(out / "strata.csv", index=False)
    mend = mendelian_table(results, data)
    mend.to_csv(out / "mendelian.csv", index=False)
    cost = cost_table(results)
    cost.to_csv(out / "cost.csv", index=False)

    titration = (
        runs.groupby(["individual", "caller", "type", "depth"])
        .agg(
            n=("f1", "size"),
            f1_mean=("f1", "mean"),
            f1_sd=("f1", "std"),
            recall_mean=("recall", "mean"),
            precision_mean=("precision", "mean"),
            coverage_est=("coverage_est", "mean"),
        )
        .reset_index()
    )
    titration.to_csv(out / "titration.csv", index=False)

    fig_titration(runs, figures / "fig1_titration.png")
    if not strata.empty:
        fig_strata(strata, figures / "fig2_strata.png")
    if not cost.empty:
        fig_cost(runs, cost, figures / "fig3_cost_accuracy.png")

    # markdown bundle consumed by docs/report.md
    sections = {
        "Bootstrap 95% CIs (30x)": boot.assign(
            recall=lambda d: d.apply(lambda r: f"{r.recall:.4f} [{r.recall_lo:.4f}, {r.recall_hi:.4f}]", axis=1),
            precision=lambda d: d.apply(
                lambda r: f"{r.precision:.4f} [{r.precision_lo:.4f}, {r.precision_hi:.4f}]", axis=1
            ),
            f1=lambda d: d.apply(lambda r: f"{r.f1:.4f} [{r.f1_lo:.4f}, {r.f1_hi:.4f}]", axis=1),
        )[["sample", "caller", "type", "recall", "precision", "f1"]],
        "Titration (mean ± SD over seeds)": titration,
        "Paired GATK vs DeepVariant on the same truth variants (exact McNemar)": paired[
            paired["sample"].str.contains("_30x")
        ]
        if not paired.empty
        else paired,
        "Stratified accuracy (30x)": strata,
        "Trio Mendelian consistency (HG002/HG003/HG004, 30x)": mend,
    }
    with open(out / "tables.md", "w") as fh:
        for title, df in sections.items():
            fh.write(f"### {title}\n\n{md_table(df) if not df.empty else '_no data_'}\n\n")
    print(json.dumps({"runs": len(runs) // 2, "outputs": sorted(p.name for p in out.iterdir())}, indent=2))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("matrix")
    m.add_argument("--results", type=Path, required=True)
    m.add_argument("--data", type=Path, required=True)
    m.add_argument("--out", type=Path, default=Path("research/results"))
    m.add_argument("--figures", type=Path, default=Path("docs/figures"))
    c = sub.add_parser("compare-vcf")
    c.add_argument("a", type=Path)
    c.add_argument("b", type=Path)
    c.add_argument("--label", default="comparison")
    c.add_argument("--out", type=Path, default=Path("research/results/reproducibility.jsonl"))
    args = ap.parse_args(argv)
    if args.cmd == "matrix":
        run_matrix(args.results, args.data, args.out, args.figures)
    else:
        res = {"label": args.label, "a": str(args.a), "b": str(args.b), **compare_vcfs(args.a, args.b)}
        args.out.parent.mkdir(parents=True, exist_ok=True)
        with open(args.out, "a") as fh:
            fh.write(json.dumps(res) + "\n")
        print(json.dumps(res, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
