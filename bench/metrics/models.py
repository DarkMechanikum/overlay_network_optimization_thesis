from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class FlowMetric:
    run_id: str
    flow_id: str
    src_port: int | None
    dst_port: int | None
    target_pps: int | None
    sender_role: str
    receiver_role: str
    status: str
    error: str | None
    pps: float | None
    bps: float | None
    latency_p50: float | None
    latency_p99: float | None
    latency_p999: float | None
    source: str


@dataclass(frozen=True)
class CpuCoreSample:
    host_role: str
    timestamp: float
    core: str
    utilization_percent: float
    source: str
    system_level: bool = True


@dataclass(frozen=True)
class HostCpuSummary:
    run_id: str
    host_role: str
    avg_utilization_percent: float | None
    core_util_cv: float | None
    top_core_utilization_percent: float | None
    bottom_core_utilization_percent: float | None
    core_count: int
    sample_count: int
    status: str
    source: str
    warnings: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class MergedMetricRow:
    run_id: str
    flow_id: str
    src_port: int | None
    dst_port: int | None
    target_pps: int | None
    sender_role: str
    receiver_role: str
    pps: float | None
    bps: float | None
    latency_p50: float | None
    latency_p99: float | None
    latency_p999: float | None
    sender_cpu_avg: float | None
    receiver_cpu_avg: float | None
    sender_cpu_core_cv: float | None
    receiver_cpu_core_cv: float | None
    sender_cpu_top_core_utilization: float | None
    receiver_cpu_top_core_utilization: float | None
    sender_cpu_bottom_core_utilization: float | None
    receiver_cpu_bottom_core_utilization: float | None
    status: str
    error: str | None
    source_refs: list[str]
