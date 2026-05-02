from __future__ import annotations

from bench.metrics.models import FlowMetric, HostCpuSummary, MergedMetricRow


def merge_flow_and_cpu_metrics(
    flow_metrics: list[FlowMetric],
    cpu_summaries: dict[str, HostCpuSummary],
) -> list[MergedMetricRow]:
    rows: list[MergedMetricRow] = []
    for flow in flow_metrics:
        sender_cpu = cpu_summaries.get(flow.sender_role)
        receiver_cpu = cpu_summaries.get(flow.receiver_role)
        missing = []
        if sender_cpu is None:
            missing.append(f"missing sender cpu summary for {flow.sender_role}")
        if receiver_cpu is None:
            missing.append(f"missing receiver cpu summary for {flow.receiver_role}")
        status = flow.status
        error = flow.error
        if missing:
            status = "partial_failure"
            error = "; ".join([msg for msg in [error, *missing] if msg])

        source_refs = [flow.source]
        if sender_cpu is not None:
            source_refs.append(sender_cpu.source)
        if receiver_cpu is not None:
            source_refs.append(receiver_cpu.source)

        rows.append(
            MergedMetricRow(
                run_id=flow.run_id,
                flow_id=flow.flow_id,
                src_port=flow.src_port,
                dst_port=flow.dst_port,
                target_pps=flow.target_pps,
                sender_role=flow.sender_role,
                receiver_role=flow.receiver_role,
                pps=flow.pps,
                bps=flow.bps,
                latency_p50=flow.latency_p50,
                latency_p99=flow.latency_p99,
                latency_p999=flow.latency_p999,
                sender_cpu_avg=sender_cpu.avg_utilization_percent if sender_cpu else None,
                receiver_cpu_avg=receiver_cpu.avg_utilization_percent if receiver_cpu else None,
                sender_cpu_core_cv=sender_cpu.core_util_cv if sender_cpu else None,
                receiver_cpu_core_cv=receiver_cpu.core_util_cv if receiver_cpu else None,
                sender_cpu_top_core_utilization=sender_cpu.top_core_utilization_percent if sender_cpu else None,
                receiver_cpu_top_core_utilization=receiver_cpu.top_core_utilization_percent if receiver_cpu else None,
                sender_cpu_bottom_core_utilization=sender_cpu.bottom_core_utilization_percent if sender_cpu else None,
                receiver_cpu_bottom_core_utilization=receiver_cpu.bottom_core_utilization_percent if receiver_cpu else None,
                status=status,
                error=error,
                source_refs=source_refs,
            )
        )
    return rows
