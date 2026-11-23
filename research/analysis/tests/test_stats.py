import math

import pytest

from gp_research.stats import Metrics, block_bootstrap, mcnemar_exact, metrics_from_labels, paired_truth_comparison


def test_metrics_basic():
    m = Metrics(tp_truth=90, fn=10, tp_query=90, fp=5)
    assert m.recall == pytest.approx(0.9)
    assert m.precision == pytest.approx(90 / 95)
    assert m.f1 == pytest.approx(2 * 0.9 * (90 / 95) / (0.9 + 90 / 95))


def test_metrics_empty_is_nan():
    assert math.isnan(Metrics(0, 0, 0, 0).f1)


def test_metrics_from_labels():
    m = metrics_from_labels(["TP", "TP", "FN"], ["TP", "FP", "TP"])
    assert (m.tp_truth, m.fn, m.tp_query, m.fp) == (2, 1, 2, 1)


@pytest.mark.parametrize(
    ("b", "c", "expected"),
    [
        (0, 0, 1.0),
        (5, 5, 1.0),
        (10, 0, 2 * 0.5**10),  # all discordant pairs favour one method
        (1, 9, 2 * (1 + 10) / 2**10),
    ],
)
def test_mcnemar_exact_known_values(b, c, expected):
    assert mcnemar_exact(b, c) == pytest.approx(expected)


def test_mcnemar_symmetric():
    assert mcnemar_exact(3, 12) == mcnemar_exact(12, 3)


def test_bootstrap_point_estimate_and_interval_cover():
    # 40 blocks of 50 kb, 25 truth variants each: 24 TP + 1 FN; 24 TP + 1 FP in the query
    truth_pos, truth_lab, query_pos, query_lab = [], [], [], []
    for b in range(40):
        base = b * 50_000 + 100
        for i in range(25):
            truth_pos.append(base + i * 10)
            truth_lab.append("FN" if i == 0 else "TP")
            query_pos.append(base + i * 10)
            query_lab.append("FP" if i == 0 else "TP")
    ci = block_bootstrap(truth_pos, truth_lab, query_pos, query_lab, 0, 2_000_000, n_boot=500)
    assert ci["recall"].estimate == pytest.approx(24 / 25)
    # perfectly uniform blocks -> zero-width interval at the estimate
    assert ci["recall"].low == pytest.approx(24 / 25)
    assert ci["recall"].high == pytest.approx(24 / 25)


def test_bootstrap_heterogeneous_blocks_give_nonzero_width():
    truth_pos = [b * 50_000 + 1 for b in range(40) for _ in range(10)]
    # errors concentrated in 4 "difficult" blocks
    truth_lab = ["FN" if (p // 50_000) < 4 else "TP" for p in truth_pos]
    ci = block_bootstrap(truth_pos, truth_lab, truth_pos, ["TP"] * len(truth_pos), 0, 2_000_000, n_boot=1000)
    assert ci["recall"].estimate == pytest.approx(0.9)
    assert ci["recall"].low < 0.9 < ci["recall"].high
    assert ci["recall"].high - ci["recall"].low > 0.05


def test_bootstrap_is_reproducible_with_seed():
    pos = list(range(1, 2_000_000, 5000))
    lab = ["TP" if i % 7 else "FN" for i in range(len(pos))]
    a = block_bootstrap(pos, lab, pos, ["TP"] * len(pos), 0, 2_000_000, seed=1)
    b = block_bootstrap(pos, lab, pos, ["TP"] * len(pos), 0, 2_000_000, seed=1)
    assert a == b


def test_bootstrap_rejects_bad_region():
    with pytest.raises(ValueError):
        block_bootstrap([], [], [], [], 10, 10)


def test_paired_comparison_counts():
    a = {("v", 1): "TP", ("v", 2): "TP", ("v", 3): "FN", ("v", 4): "FN"}
    b = {("v", 1): "TP", ("v", 2): "FN", ("v", 3): "TP", ("v", 4): "FN"}
    out = paired_truth_comparison(a, b)
    assert (out["both_found"], out["only_a"], out["only_b"], out["neither"]) == (1, 1, 1, 1)
    assert out["recall_a"] == out["recall_b"] == 0.5
    assert out["p_mcnemar"] == 1.0
