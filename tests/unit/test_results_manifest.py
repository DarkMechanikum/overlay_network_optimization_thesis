from __future__ import annotations

import json
from pathlib import Path

from bench.context import BenchParams, HostConfig, RunContext, StageResult
from bench.results.manifest import build_manifest_payload, write_manifest


def _ctx(tmp_path: Path) -> RunContext:
    return RunContext(
        repo_root=tmp_path,
        host1=HostConfig(role="host1", ip="1.1.1.1", ssh_hostname="h1", key_path=tmp_path / "k1"),
        host2=HostConfig(role="host2", ip="2.2.2.2", ssh_hostname="h2", key_path=tmp_path / "k2"),
        bench_params=BenchParams(),
        run_id="run1",
        artifacts_root=tmp_path / "artifacts" / "run1",
    )


def test_manifest_writer_contains_required_fields(tmp_path: Path) -> None:
    ctx = _ctx(tmp_path)
    ctx.stage_results["benchmark"] = StageResult(success=True, payload={"synthetic_telemetry": True, "telemetry_source": "synthetic"})
    payload = build_manifest_payload(
        ctx,
        stage_names=["preflight", "cleanup"],
        artifact_paths={"a": "b"},
        result_csv_path="results/result.csv",
    )
    out = write_manifest(tmp_path / "artifacts" / "run1" / "run.json", payload)
    raw = json.loads(out.read_text(encoding="utf-8"))
    assert raw["run_id"] == "run1"
    assert "params" in raw
    assert "artifact_paths" in raw
    assert raw["result_csv_path"] == "results/result.csv"
    assert raw["synthetic_metrics"] is True
    assert raw["telemetry_source"] == "synthetic"
