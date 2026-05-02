from __future__ import annotations

import pytest

from bench.metrics.cpu import align_cpu_samples_to_window, parse_mpstat_text, summarize_cpu_samples


def test_cpu_parser_extracts_two_cores_and_utilization() -> None:
    text = "\n".join(
        [
            "1.0 0 90.0",
            "1.0 1 80.0",
            "2.0 0 70.0",
            "2.0 1 60.0",
        ]
    )
    samples = parse_mpstat_text("host1", text, source="fixture")
    assert len(samples) == 4
    assert samples[0].core == "0"
    assert samples[0].utilization_percent == pytest.approx(10.0)
    assert samples[1].utilization_percent == pytest.approx(20.0)


def test_cpu_window_alignment_and_summary() -> None:
    """Short bins (default 10 ms): each bin picks max/min core util at that instant; then averages bins."""
    text = "\n".join(
        [
            "0.5 0 90.0",
            "1.0 0 80.0",
            "2.0 0 70.0",
            "3.0 0 60.0",
            "2.0 1 50.0",
        ]
    )
    samples = parse_mpstat_text("host2", text, source="fixture")
    aligned = align_cpu_samples_to_window(samples, window_start=1.0, window_end=2.5)
    summary = summarize_cpu_samples("r1", "host2", aligned, source="fixture", window_seconds=0.01)
    assert summary.status == "ok"
    assert summary.core_count == 2
    assert summary.sample_count == 3
    # t=1.0: only core0 -> util 20; t=2.0: core0 30, core1 50 -> two bins
    assert summary.avg_utilization_percent == pytest.approx(30.0)
    assert summary.top_core_utilization_percent == pytest.approx(35.0)
    assert summary.bottom_core_utilization_percent == pytest.approx(25.0)
    assert summary.core_util_cv == pytest.approx(0.125)


def test_cpu_summary_single_wide_window_matches_global_per_core_aggregate() -> None:
    """One bin spanning all samples: same as averaging samples per core then global top/min/CV."""
    text = "\n".join(
        [
            "0.5 0 90.0",
            "1.0 0 80.0",
            "2.0 0 70.0",
            "3.0 0 60.0",
            "2.0 1 50.0",
        ]
    )
    samples = parse_mpstat_text("host2", text, source="fixture")
    aligned = align_cpu_samples_to_window(samples, window_start=1.0, window_end=2.5)
    summary = summarize_cpu_samples("r1", "host2", aligned, source="fixture", window_seconds=2.0)
    assert summary.status == "ok"
    assert summary.avg_utilization_percent == pytest.approx((25 + 50) / 2)
    assert summary.top_core_utilization_percent == pytest.approx(50.0)
    assert summary.bottom_core_utilization_percent == pytest.approx(25.0)
    assert summary.core_util_cv == pytest.approx(0.3333333333, rel=1e-6)
