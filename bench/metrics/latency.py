from __future__ import annotations

import math
from typing import Iterable


def _nearest_rank_quantile(sorted_values: list[float], q: float) -> float:
    if not sorted_values:
        raise ValueError("empty values")
    rank = max(1, math.ceil(q * len(sorted_values)))
    return sorted_values[rank - 1]


def compute_latency_quantiles(samples: Iterable[object]) -> dict[str, float | None | str]:
    valid: list[float] = []
    malformed = 0
    for value in samples:
        if isinstance(value, (int, float)):
            valid.append(float(value))
        else:
            malformed += 1

    if not valid:
        return {
            "status": "missing_data" if malformed == 0 else "malformed_data",
            "p50": None,
            "p99": None,
            "p999": None,
        }

    valid.sort()
    status = "ok" if malformed == 0 else "partial_malformed"
    return {
        "status": status,
        "p50": _nearest_rank_quantile(valid, 0.50),
        "p99": _nearest_rank_quantile(valid, 0.99),
        "p999": _nearest_rank_quantile(valid, 0.999),
    }
