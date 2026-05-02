from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from bench.context import RunContext


def build_manifest_payload(
    ctx: RunContext,
    *,
    stage_names: list[str],
    artifact_paths: dict[str, str],
    result_csv_path: str,
) -> dict[str, Any]:
    benchmark_payload = ctx.stage_results.get("benchmark").payload if ctx.stage_results.get("benchmark") else {}
    synthetic_metrics = bool(benchmark_payload.get("synthetic_telemetry"))
    return {
        "run_id": ctx.run_id,
        "repo_root": str(ctx.repo_root),
        "params": {
            "connections": ctx.bench_params.connections,
            "duration_seconds": ctx.bench_params.duration_seconds,
            "warmup_seconds": ctx.bench_params.warmup_seconds,
            "cooldown_seconds": ctx.bench_params.cooldown_seconds,
            "packet_size": ctx.bench_params.packet_size,
            "base_pps": ctx.bench_params.base_pps,
        },
        "hosts": {
            "host1": {"role": ctx.host1.role, "ssh_hostname": ctx.host1.ssh_hostname, "ip": ctx.host1.ip},
            "host2": {"role": ctx.host2.role, "ssh_hostname": ctx.host2.ssh_hostname, "ip": ctx.host2.ip},
        },
        "stages": stage_names,
        "artifact_paths": artifact_paths,
        "result_csv_path": result_csv_path,
        "synthetic_metrics": synthetic_metrics,
        "telemetry_source": benchmark_payload.get("telemetry_source", "unknown"),
    }


def write_manifest(path: Path, payload: dict[str, Any]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return path
