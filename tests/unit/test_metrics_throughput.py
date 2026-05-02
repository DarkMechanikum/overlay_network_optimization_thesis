from __future__ import annotations

import pytest

from bench.metrics.throughput import (
    compute_throughput_from_counter_samples,
    compute_throughput_from_counts,
    measurement_window_bounds,
)


def test_throughput_from_counts_known_values() -> None:
    out = compute_throughput_from_counts(packet_count=1000, packet_size_bytes=128, window_seconds=2.0)
    assert out["pps"] == 500.0
    assert out["bps"] == 500.0 * 128 * 8


def test_warmup_cooldown_window_exclusion() -> None:
    ws, we = measurement_window_bounds(start_ts=0.0, duration_seconds=10.0, warmup_seconds=2.0, cooldown_seconds=2.0)
    assert ws == 2.0
    assert we == 8.0

    samples = [
        {"timestamp": 1.0, "packet_count": 50},
        {"timestamp": 2.0, "packet_count": 100},
        {"timestamp": 5.0, "packet_count": 400},
        {"timestamp": 8.0, "packet_count": 700},
        {"timestamp": 9.0, "packet_count": 900},
    ]
    out = compute_throughput_from_counter_samples(samples, window_start=ws, window_end=we, packet_size_bytes=100)
    assert out["status"] == "ok"
    assert out["pps"] == pytest.approx((700 - 100) / (8.0 - 2.0))

