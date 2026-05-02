from __future__ import annotations

from bench.metrics.merge import merge_flow_and_cpu_metrics
from bench.metrics.models import FlowMetric, HostCpuSummary


def test_merge_joins_flow_and_cpu_and_marks_partial_on_missing_cpu() -> None:
    flow = FlowMetric(
        run_id="run1",
        flow_id="f1",
        src_port=20001,
        dst_port=30001,
        target_pps=100,
        sender_role="host1",
        receiver_role="host2",
        status="ok",
        error=None,
        pps=100.0,
        bps=80000.0,
        latency_p50=10.0,
        latency_p99=20.0,
        latency_p999=30.0,
        source="flow.json",
    )
    cpu = {
        "host1": HostCpuSummary(
            run_id="run1",
            host_role="host1",
            avg_utilization_percent=35.0,
            core_util_cv=0.1,
            top_core_utilization_percent=40.0,
            bottom_core_utilization_percent=30.0,
            core_count=2,
            sample_count=4,
            status="ok",
            source="cpu1.txt",
        )
    }
    rows = merge_flow_and_cpu_metrics([flow], cpu)
    assert len(rows) == 1
    assert rows[0].sender_cpu_avg == 35.0
    assert rows[0].sender_cpu_core_cv == 0.1
    assert rows[0].sender_cpu_top_core_utilization == 40.0
    assert rows[0].sender_cpu_bottom_core_utilization == 30.0
    assert rows[0].receiver_cpu_avg is None
    assert rows[0].status == "partial_failure"
