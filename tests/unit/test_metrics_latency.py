from __future__ import annotations

from bench.metrics.latency import compute_latency_quantiles


def test_quantiles_known_dataset() -> None:
    out = compute_latency_quantiles([10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
    assert out["status"] == "ok"
    assert out["p50"] == 50
    assert out["p99"] == 100
    assert out["p999"] == 100


def test_quantiles_edge_cases_empty_single_malformed() -> None:
    empty = compute_latency_quantiles([])
    assert empty["status"] == "missing_data"
    assert empty["p50"] is None

    single = compute_latency_quantiles([7])
    assert single["status"] == "ok"
    assert single["p50"] == 7
    assert single["p99"] == 7

    malformed = compute_latency_quantiles([1, "x", 3])
    assert malformed["status"] == "partial_malformed"
    assert malformed["p50"] == 1
