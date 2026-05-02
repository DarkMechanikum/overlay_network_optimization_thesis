from __future__ import annotations

from collections import defaultdict
from statistics import pstdev

from bench.metrics.models import CpuCoreSample, HostCpuSummary


def parse_mpstat_text(host_role: str, text: str, *, source: str = "mpstat") -> list[CpuCoreSample]:
    samples: list[CpuCoreSample] = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or "CPU" in stripped and "%idle" in stripped:
            continue
        parts = stripped.split()
        if len(parts) < 3:
            continue
        # Supports compact fixture format: "<ts> <cpu> <idle>"
        # and full mpstat where idle is the last column.
        try:
            timestamp = float(parts[0])
            core = parts[1]
            idle = float(parts[-1])
        except ValueError:
            continue
        util = max(0.0, min(100.0, 100.0 - idle))
        samples.append(
            CpuCoreSample(
                host_role=host_role,
                timestamp=timestamp,
                core=core,
                utilization_percent=util,
                source=source,
                system_level=True,
            )
        )
    return samples


def align_cpu_samples_to_window(
    samples: list[CpuCoreSample], *, window_start: float, window_end: float
) -> list[CpuCoreSample]:
    return [s for s in samples if window_start <= s.timestamp <= window_end]


def summarize_cpu_samples(
    run_id: str,
    host_role: str,
    samples: list[CpuCoreSample],
    *,
    source: str,
    window_seconds: float = 0.01,
) -> HostCpuSummary:
    if not samples:
        return HostCpuSummary(
            run_id=run_id,
            host_role=host_role,
            avg_utilization_percent=None,
            core_util_cv=None,
            top_core_utilization_percent=None,
            bottom_core_utilization_percent=None,
            core_count=0,
            sample_count=0,
            status="missing_data",
            source=source,
            warnings=["no cpu samples in measurement window"],
        )

    per_core_all: set[str] = {s.core for s in samples}
    t_min = min(s.timestamp for s in samples)
    t_max = max(s.timestamp for s in samples)
    span = max(t_max - t_min, 0.0)
    w = window_seconds
    if w <= 0:
        w = max(span, 1e-9)

    # window_index -> core -> list of utilizations
    bins: dict[int, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    for sample in samples:
        idx = int((sample.timestamp - t_min) / w)
        bins[idx][sample.core].append(sample.utilization_percent)

    mean_per_window: list[float] = []
    top_per_window: list[float] = []
    bottom_per_window: list[float] = []
    cv_per_window: list[float] = []

    for _wi, core_map in sorted(bins.items()):
        per_core_avg = [sum(vals) / len(vals) for vals in core_map.values() if vals]
        if not per_core_avg:
            continue
        mean_w = sum(per_core_avg) / len(per_core_avg)
        top_w = max(per_core_avg)
        bottom_w = min(per_core_avg)
        if len(per_core_avg) > 1 and mean_w > 0:
            cv_w = pstdev(per_core_avg) / mean_w
        else:
            cv_w = 0.0
        mean_per_window.append(mean_w)
        top_per_window.append(top_w)
        bottom_per_window.append(bottom_w)
        cv_per_window.append(cv_w)

    if not mean_per_window:
        return HostCpuSummary(
            run_id=run_id,
            host_role=host_role,
            avg_utilization_percent=None,
            core_util_cv=None,
            top_core_utilization_percent=None,
            bottom_core_utilization_percent=None,
            core_count=len(per_core_all),
            sample_count=len(samples),
            status="missing_data",
            source=source,
            warnings=["no cpu samples could be binned"],
        )

    n_win = len(mean_per_window)
    return HostCpuSummary(
        run_id=run_id,
        host_role=host_role,
        avg_utilization_percent=sum(mean_per_window) / n_win,
        core_util_cv=sum(cv_per_window) / n_win,
        top_core_utilization_percent=sum(top_per_window) / n_win,
        bottom_core_utilization_percent=sum(bottom_per_window) / n_win,
        core_count=len(per_core_all),
        sample_count=len(samples),
        status="ok",
        source=source,
    )
