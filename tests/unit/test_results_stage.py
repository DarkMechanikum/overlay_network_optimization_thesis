from __future__ import annotations
from pathlib import Path

from bench.context import BenchParams, HostConfig, RunContext, StageResult
from bench.stages.results_stage import run_results_stage


def _ctx(tmp_path: Path) -> RunContext:
    return RunContext(
        repo_root=tmp_path,
        host1=HostConfig(role="host1", ip="1.1.1.1", ssh_hostname="h1", key_path=tmp_path / "k1"),
        host2=HostConfig(role="host2", ip="2.2.2.2", ssh_hostname="h2", key_path=tmp_path / "k2"),
        bench_params=BenchParams(connections=2, duration_seconds=10, packet_size=128),
        run_id="run1",
        artifacts_root=tmp_path / "artifacts" / "run1",
    )


def test_results_stage_creates_dirs_and_surfaces_paths(tmp_path: Path) -> None:
    ctx = _ctx(tmp_path)
    ctx.stage_results["benchmark"] = StageResult(success=True, payload={"artifact_paths": {"flow_profile": "x.json"}})
    ctx.stage_results["metrics"] = StageResult(
        success=True,
        payload={
            "flow_metrics": [{"flow_id": "f1"}, {"flow_id": "f2"}],
            "merged_rows": [
                {"flow_id": "f1", "src_port": 1, "dst_port": 2, "status": "ok"},
                {"flow_id": "f2", "src_port": 3, "dst_port": 4, "status": "partial_failure", "error": "e"},
            ],
            "artifact_paths": {"normalized_metrics": "norm.json"},
        },
    )
    result = run_results_stage(ctx)
    assert result.success
    assert Path(result.payload["result_csv_path"]).exists()
    assert Path(result.payload["artifact_result_csv_path"]).exists()
    assert Path(result.payload["artifact_run_dir"]).exists()
    assert Path(result.payload["manifest_path"]).exists()
    assert Path(result.payload["artifact_result_csv_path"]).parent == Path(result.payload["artifact_run_dir"])


def test_results_stage_integrity_error_on_row_count_mismatch(tmp_path: Path) -> None:
    ctx = _ctx(tmp_path)
    ctx.stage_results["metrics"] = StageResult(
        success=True,
        payload={
            "flow_metrics": [{"flow_id": "f1"}, {"flow_id": "f2"}],
            "merged_rows": [{"flow_id": "f1", "src_port": 1, "dst_port": 2, "status": "ok"}],
            "artifact_paths": {},
        },
    )
    result = run_results_stage(ctx)
    assert not result.success
    assert any("row count mismatch" in e for e in result.payload["validation_errors"])
