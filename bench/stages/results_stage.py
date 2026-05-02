from __future__ import annotations

import shutil
from datetime import datetime, timezone

from bench.artifacts.layout import ensure_artifact_layout
from bench.artifacts.sink import register_existing_artifacts
from bench.context import RunContext, StageResult
from bench.results.csv_writer import validate_metric_rows, write_metrics_csv
from bench.results.manifest import build_manifest_payload, write_manifest
from bench.results.paths import ensure_results_dir, resolve_indexed_result_csv


def run_results_stage(ctx: RunContext) -> StageResult:
    metrics = ctx.stage_results.get("metrics")
    if metrics is None or not metrics.payload:
        return StageResult(success=False, message="Results stage requires metrics output", payload={})

    layout = ensure_artifact_layout(ctx.repo_root, ctx.run_id)
    results_dir = ensure_results_dir(ctx.repo_root)
    result_csv_path = resolve_indexed_result_csv(results_dir)

    metric_rows = metrics.payload.get("merged_rows", [])
    expected_rows = metrics.payload.get("flow_metrics")
    expected_count = len(expected_rows) if isinstance(expected_rows, list) else None

    rows_for_csv = []
    run_timestamp = datetime.now(timezone.utc).isoformat()
    for row in metric_rows:
        csv_row = {
            "run_id": ctx.run_id,
            "run_timestamp": run_timestamp,
            "duration_seconds": ctx.bench_params.duration_seconds,
            "connection_count": ctx.bench_params.connections,
            "packet_size": ctx.bench_params.packet_size,
            "host1_id": ctx.host1.ssh_hostname,
            "host2_id": ctx.host2.ssh_hostname,
            "flow_id": row.get("flow_id"),
            "src_port": row.get("src_port"),
            "dst_port": row.get("dst_port"),
            "target_pps": row.get("target_pps"),
            "pps": row.get("pps"),
            "bps": row.get("bps"),
            "latency_p50": row.get("latency_p50"),
            "latency_p99": row.get("latency_p99"),
            "latency_p999": row.get("latency_p999"),
            "sender_cpu_avg": row.get("sender_cpu_avg"),
            "receiver_cpu_avg": row.get("receiver_cpu_avg"),
            "sender_cpu_core_cv": row.get("sender_cpu_core_cv"),
            "receiver_cpu_core_cv": row.get("receiver_cpu_core_cv"),
            "sender_cpu_top_core_utilization": row.get("sender_cpu_top_core_utilization"),
            "receiver_cpu_top_core_utilization": row.get("receiver_cpu_top_core_utilization"),
            "sender_cpu_bottom_core_utilization": row.get("sender_cpu_bottom_core_utilization"),
            "receiver_cpu_bottom_core_utilization": row.get("receiver_cpu_bottom_core_utilization"),
            "status": row.get("status"),
            "error": row.get("error"),
        }
        rows_for_csv.append(csv_row)

    validation_errors = validate_metric_rows(rows_for_csv, expected_count=expected_count)
    write_metrics_csv(result_csv_path, rows_for_csv)
    artifact_csv_path = layout["run_root"] / result_csv_path.name
    shutil.copy2(result_csv_path, artifact_csv_path)

    existing_refs = register_existing_artifacts(
        {
            "benchmark_flow_profile": ctx.stage_results.get("benchmark", StageResult(True)).payload.get("artifact_paths", {}).get(
                "flow_profile"
            ),
            "metrics_normalized": metrics.payload.get("artifact_paths", {}).get("normalized_metrics"),
        }
    )
    manifest_payload = build_manifest_payload(
        ctx,
        stage_names=list(ctx.stage_results.keys()) + ["results"],
        artifact_paths={
            **existing_refs,
            "run_root": str(layout["run_root"]),
            "local": str(layout["local"]),
            "result_csv": str(result_csv_path),
            "artifact_result_csv": str(artifact_csv_path),
        },
        result_csv_path=str(result_csv_path),
    )
    manifest_path = write_manifest(layout["run_root"] / "run.json", manifest_payload)

    success = not validation_errors
    message = "Results stage completed" if success else "Results stage completed with integrity errors"
    return StageResult(
        success=success,
        message=message,
        payload={
            "result_csv_path": str(result_csv_path),
            "artifact_run_dir": str(layout["run_root"]),
            "manifest_path": str(manifest_path),
            "artifact_result_csv_path": str(artifact_csv_path),
            "row_count": len(rows_for_csv),
            "validation_errors": validation_errors,
        },
    )
