from __future__ import annotations

from typing import Sequence


def measurement_window_bounds(
    *,
    start_ts: float,
    duration_seconds: float,
    warmup_seconds: float,
    cooldown_seconds: float,
) -> tuple[float, float]:
    window_start = start_ts + max(0.0, warmup_seconds)
    window_end = start_ts + max(0.0, duration_seconds - cooldown_seconds)
    if window_end <= window_start:
        raise ValueError("invalid measurement window; check warmup/cooldown/duration values")
    return window_start, window_end


def compute_throughput_from_counts(packet_count: int, packet_size_bytes: int, window_seconds: float) -> dict[str, float]:
    if window_seconds <= 0:
        raise ValueError("window_seconds must be > 0")
    if packet_count < 0:
        raise ValueError("packet_count must be >= 0")
    if packet_size_bytes <= 0:
        raise ValueError("packet_size_bytes must be > 0")
    pps = packet_count / window_seconds
    bps = pps * packet_size_bytes * 8
    return {"pps": pps, "bps": bps}


def compute_throughput_from_counter_samples(
    samples: Sequence[dict[str, float | int]],
    *,
    window_start: float,
    window_end: float,
    packet_size_bytes: int,
) -> dict[str, float | str | None]:
    in_window = [s for s in samples if window_start <= float(s["timestamp"]) <= window_end]
    if len(in_window) < 2:
        return {"status": "missing_data", "pps": None, "bps": None}

    first = in_window[0]
    last = in_window[-1]
    delta_packets = int(last["packet_count"]) - int(first["packet_count"])
    delta_time = float(last["timestamp"]) - float(first["timestamp"])
    if delta_packets < 0 or delta_time <= 0:
        return {"status": "invalid_data", "pps": None, "bps": None}

    metrics = compute_throughput_from_counts(delta_packets, packet_size_bytes, delta_time)
    return {"status": "ok", "pps": metrics["pps"], "bps": metrics["bps"]}
