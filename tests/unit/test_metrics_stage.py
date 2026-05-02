from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path

from bench.context import BenchParams, HostConfig, RunContext, StageResult
from bench.stages.metrics_stage import run_metrics_stage


def _ctx(tmp_path: Path) -> RunContext:
    host1 = HostConfig(role="host1", ip="1.1.1.1", ssh_hostname="h1", key_path=tmp_path / "k1")
    host2 = HostConfig(role="host2", ip="2.2.2.2", ssh_hostname="h2", key_path=tmp_path / "k2")
    return RunContext(
        repo_root=tmp_path,
        host1=host1,
        host2=host2,
        bench_params=BenchParams(duration_seconds=10, warmup_seconds=2, cooldown_seconds=2, packet_size=100),
        run_id="run1",
        artifacts_root=tmp_path / "artifacts" / "run1",
    )


def test_metrics_stage_output_contract_success(tmp_path: Path) -> None:
    ctx = _ctx(tmp_path)
    cpu_sender = ctx.artifacts_root / "local" / "cpu-sender.txt"
    cpu_receiver = ctx.artifacts_root / "local" / "cpu-receiver.txt"
    cpu_sender.parent.mkdir(parents=True, exist_ok=True)
    cpu_sender.write_text("1.0 0 90.0\n2.0 0 80.0\n", encoding="utf-8")
    cpu_receiver.write_text("1.0 0 70.0\n2.0 0 60.0\n", encoding="utf-8")

    ctx.stage_results["benchmark"] = StageResult(
        success=True,
        payload={
            "per_flow_status": [
                {
                    "flow_id": "flow-0",
                    "src_port": 20000,
                    "dst_port": 30000,
                    "target_pps": 100,
                    "status": "established",
                    "sender_role": "host1",
                    "receiver_role": "host2",
                    "latency_samples": [10, 20, 30],
                    "counter_samples": [
                        {"timestamp": 2.0, "packet_count": 100},
                        {"timestamp": 8.0, "packet_count": 700},
                    ],
                }
            ],
            "artifact_paths": {"raw_status": "raw.json", "cpu_sender": str(cpu_sender), "cpu_receiver": str(cpu_receiver)},
        },
    )
    result = run_metrics_stage(ctx)
    assert result.success
    assert {"flow_metrics", "cpu_summaries", "merged_rows", "artifact_paths"} <= set(result.payload.keys())
    assert result.payload["flow_metrics"][0]["pps"] == 100.0
    assert Path(result.payload["artifact_paths"]["normalized_metrics"]).exists()
    host1 = result.payload["cpu_summaries"]["host1"]
    assert host1["status"] == "ok"
    assert host1["top_core_utilization_percent"] == host1["bottom_core_utilization_percent"]


def test_metrics_stage_handles_missing_flow_data(tmp_path: Path) -> None:
    ctx = _ctx(tmp_path)
    ctx.stage_results["benchmark"] = StageResult(
        success=True,
        payload={
            "per_flow_status": [
                {"flow_id": "flow-0", "status": "not-established", "target_pps": 100, "sender_role": "host1", "receiver_role": "host2"}
            ],
            "artifact_paths": {},
        },
    )
    result = run_metrics_stage(ctx)
    assert result.success
    assert result.payload["flow_metrics"][0]["status"] == "partial_failure"


def test_metrics_stage_cpu_summary_uses_window_averaging(tmp_path: Path) -> None:
    ctx = _ctx(tmp_path)
    ctx.bench_params = replace(ctx.bench_params, cpu_window_seconds=0.01)
    cpu_sender = ctx.artifacts_root / "local" / "cpu-sender.txt"
    cpu_receiver = ctx.artifacts_root / "local" / "cpu-receiver.txt"
    cpu_sender.parent.mkdir(parents=True, exist_ok=True)
    cpu_sender.write_text(
        "\n".join(
            [
                "2.0 0 80.0",  # util 20
                "2.0 1 60.0",  # util 40
                "3.0 0 50.0",  # util 50
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    cpu_receiver.write_text("2.0 0 70.0\n", encoding="utf-8")

    ctx.stage_results["benchmark"] = StageResult(
        success=True,
        payload={
            "per_flow_status": [
                {
                    "flow_id": "flow-0",
                    "src_port": 20000,
                    "dst_port": 30000,
                    "target_pps": 100,
                    "status": "established",
                    "sender_role": "host1",
                    "receiver_role": "host2",
                    "latency_samples": [10, 20, 30],
                    "counter_samples": [
                        {"timestamp": 2.0, "packet_count": 100},
                        {"timestamp": 8.0, "packet_count": 700},
                    ],
                }
            ],
            "artifact_paths": {"raw_status": "raw.json", "cpu_sender": str(cpu_sender), "cpu_receiver": str(cpu_receiver)},
        },
    )
    result = run_metrics_stage(ctx)
    assert result.success
    host1 = result.payload["cpu_summaries"]["host1"]
    assert host1["status"] == "ok"
    assert host1["avg_utilization_percent"] == 40.0
    assert host1["top_core_utilization_percent"] == 45.0
    assert host1["bottom_core_utilization_percent"] == 35.0
    assert host1["core_util_cv"] == 0.16666666666666666

