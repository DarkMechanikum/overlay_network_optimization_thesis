from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path
from typing import Any

from bench.context import RunContext, StageResult
from bench.metrics.cpu import align_cpu_samples_to_window, parse_mpstat_text, summarize_cpu_samples
from bench.metrics.latency import compute_latency_quantiles
from bench.metrics.merge import merge_flow_and_cpu_metrics
from bench.metrics.models import FlowMetric
from bench.metrics.throughput import (
    compute_throughput_from_counts,
    compute_throughput_from_counter_samples,
    measurement_window_bounds,
)


def _load_optional_text(path: str | None) -> str:
    if not path:
        return ""
    p = Path(path)
    if not p.exists():
        return ""
    return p.read_text(encoding="utf-8")


def run_metrics_stage(ctx: RunContext) -> StageResult:
    benchmark = ctx.stage_results.get("benchmark")
    if benchmark is None or not benchmark.payload:
        return StageResult(success=False, message="Metrics stage requires benchmark output", payload={})

    try:
        window_start, window_end = measurement_window_bounds(
            start_ts=0.0,
            duration_seconds=ctx.bench_params.duration_seconds,
            warmup_seconds=ctx.bench_params.warmup_seconds,
            cooldown_seconds=ctx.bench_params.cooldown_seconds,
        )
    except ValueError as exc:
        return StageResult(success=False, message="Metrics stage invalid measurement window", payload={"error": str(exc)})

    flow_metrics: list[FlowMetric] = []
    warnings: list[str] = []
    for flow in benchmark.payload.get("per_flow_status", []):
        flow_status = flow.get("status", "unknown")
        latency = compute_latency_quantiles(flow.get("latency_samples", []))

        throughput_status = "missing_data"
        pps = None
        bps = None
        if isinstance(flow.get("counter_samples"), list):
            t = compute_throughput_from_counter_samples(
                flow["counter_samples"],
                window_start=window_start,
                window_end=window_end,
                packet_size_bytes=ctx.bench_params.packet_size,
            )
            throughput_status = str(t["status"])
            pps = t["pps"]  # type: ignore[assignment]
            bps = t["bps"]  # type: ignore[assignment]
        elif flow_status == "established":
            window_seconds = window_end - window_start
            estimated_packets = int(flow.get("target_pps", 0) * window_seconds)
            t = compute_throughput_from_counts(estimated_packets, ctx.bench_params.packet_size, window_seconds)
            throughput_status = "estimated"
            pps = t["pps"]
            bps = t["bps"]

        status = "ok" if flow_status == "established" else "partial_failure"
        error = None
        if flow_status != "established":
            error = f"flow not established: {flow.get('flow_id')}"
        if latency["status"] != "ok":
            status = "partial_failure"
            warning = f"latency missing/partial for flow {flow.get('flow_id')}: {latency['status']}"
            warnings.append(warning)
        if throughput_status in {"missing_data", "invalid_data"}:
            status = "partial_failure"
            warning = f"throughput {throughput_status} for flow {flow.get('flow_id')}"
            warnings.append(warning)

        flow_metrics.append(
            FlowMetric(
                run_id=ctx.run_id,
                flow_id=str(flow.get("flow_id")),
                src_port=int(flow.get("src_port")) if flow.get("src_port") is not None else None,
                dst_port=int(flow.get("dst_port")) if flow.get("dst_port") is not None else None,
                target_pps=int(flow.get("target_pps")) if flow.get("target_pps") is not None else None,
                sender_role=str(flow.get("sender_role", "host1")),
                receiver_role=str(flow.get("receiver_role", "host2")),
                status=status,
                error=error,
                pps=pps,
                bps=bps,
                latency_p50=latency["p50"],  # type: ignore[arg-type]
                latency_p99=latency["p99"],  # type: ignore[arg-type]
                latency_p999=latency["p999"],  # type: ignore[arg-type]
                source=benchmark.payload.get("artifact_paths", {}).get("raw_status", "benchmark-stage"),
            )
        )

    artifacts = benchmark.payload.get("artifact_paths", {})
    sender_cpu_text = _load_optional_text(artifacts.get("cpu_sender"))
    receiver_cpu_text = _load_optional_text(artifacts.get("cpu_receiver"))

    sender_cpu = parse_mpstat_text("host1", sender_cpu_text, source=artifacts.get("cpu_sender", "missing"))
    receiver_cpu = parse_mpstat_text("host2", receiver_cpu_text, source=artifacts.get("cpu_receiver", "missing"))
    sender_cpu = align_cpu_samples_to_window(sender_cpu, window_start=window_start, window_end=window_end)
    receiver_cpu = align_cpu_samples_to_window(receiver_cpu, window_start=window_start, window_end=window_end)
    w_cpu = ctx.bench_params.cpu_window_seconds
    cpu_summaries = {
        "host1": summarize_cpu_samples(
            ctx.run_id, "host1", sender_cpu, source=artifacts.get("cpu_sender", "missing"), window_seconds=w_cpu
        ),
        "host2": summarize_cpu_samples(
            ctx.run_id, "host2", receiver_cpu, source=artifacts.get("cpu_receiver", "missing"), window_seconds=w_cpu
        ),
    }
    for summary in cpu_summaries.values():
        warnings.extend(summary.warnings)

    merged = merge_flow_and_cpu_metrics(flow_metrics, cpu_summaries)
    metrics_payload = {
        "run_id": ctx.run_id,
        "flow_metrics": [asdict(metric) for metric in flow_metrics],
        "cpu_summaries": {k: asdict(v) for k, v in cpu_summaries.items()},
        "merged_rows": [asdict(row) for row in merged],
        "warnings": warnings,
        "errors": [],
    }
    metrics_artifact = ctx.artifacts_root / "local" / "normalized-metrics.json"
    metrics_artifact.parent.mkdir(parents=True, exist_ok=True)
    metrics_artifact.write_text(json.dumps(metrics_payload, indent=2, sort_keys=True), encoding="utf-8")
    metrics_payload["artifact_paths"] = {"normalized_metrics": str(metrics_artifact)}

    return StageResult(
        success=True,
        message="Metrics stage completed",
        payload=metrics_payload,
    )
