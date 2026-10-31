"""
NorthStar Retail — Fairness Check
CS 401R Lab 4

A manual slice evaluation by loyalty tier. train() writes per-tier results into
evaluation_metrics.json as slice_results, using the same top-10% cutoff as the
aggregate recall, and buildspec.yml runs this file in the build phase next to
test_model.py.

The recall gap FLAGS, it does not block. It is expected to fire on this data:
the point is that it is visible to the approver, not that it is quiet. Do not
turn the warning into an assert, because that would make a known property of the
data fail every build.

Run locally (after the local training run in the lab handout):
    pytest tests/test_fairness.py -v -rw --eval-metrics-path /tmp/out/evaluation_metrics.json
"""

import json
import os
import warnings
from pathlib import Path

import pytest

TIERS = {"Bronze", "Silver", "Gold", "Platinum"}
LOWEST_TIER = "Bronze"
HIGHEST_TIER = "Platinum"
MAX_RECALL_GAP = 0.10   # 10 percentage points


@pytest.fixture(scope="module")
def slice_results():
    """A missing metrics file FAILS rather than skips: SKIPPED is not a pass,
    and a fairness check that cannot see the metrics has checked nothing."""
    metrics_path = os.environ.get("EVAL_METRICS_PATH", "/tmp/eval_metrics.json")
    if not Path(metrics_path).exists():
        pytest.fail(f"Evaluation metrics not found at {metrics_path}.", pytrace=False)
    with open(metrics_path) as f:
        metrics = json.load(f)
    assert "slice_results" in metrics, (
        "slice_results missing from evaluation metrics. train() in "
        "models/churn/churn_model.py must add the per-tier results."
    )
    return metrics["slice_results"]


def test_every_tier_is_evaluated(slice_results):
    assert set(slice_results) == TIERS


def test_slices_report_their_size(slice_results):
    """A slice metric without its n and positives is not a measurement."""
    for tier, result in slice_results.items():
        assert result["n"] > 0, f"{tier} has no test rows"
        assert 0 <= result["positives"] <= result["n"], f"{tier}: {result}"
        assert result["recall_top10"] is None or 0 <= result["recall_top10"] <= 1, f"{tier}: {result}"


def test_tier_recall_gap_is_flagged(slice_results):
    """Flag, do not block, a recall gap over 10 points between tiers."""
    lowest = slice_results[LOWEST_TIER]
    highest = slice_results[HIGHEST_TIER]
    assert lowest["recall_top10"] is not None and highest["recall_top10"] is not None, (
        f"Cannot compare {LOWEST_TIER} and {HIGHEST_TIER}: a tier has no churners"
    )

    gap = abs(lowest["recall_top10"] - highest["recall_top10"])
    if gap > MAX_RECALL_GAP:
        by_tier = "; ".join(
            f"{tier} recall={r['recall_top10']} (n={r['n']}, positives={r['positives']}"
            f"{', too small to conclude from' if r['too_small'] else ''})"
            for tier, r in sorted(slice_results.items())
        )
        warnings.warn(
            f"FAIRNESS FLAG: recall gap {gap:.1%} between {LOWEST_TIER} and "
            f"{HIGHEST_TIER} exceeds {MAX_RECALL_GAP:.0%}. {by_tier}"
        )
