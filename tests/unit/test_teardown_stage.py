from __future__ import annotations

from dataclasses import replace
from typing import Any
from unittest.mock import patch

from bench.context import StageResult
from bench.remote.ssh import CommandResult
from bench.stages.teardown import run_teardown_stage


def _ok() -> CommandResult:
    return CommandResult(argv=["ssh"], returncode=0, stdout="", stderr="")


def test_teardown_keep_containers_true_skips_cleanup(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(run_context_minimal.bench_params, keep_containers=True)
    result = run_teardown_stage(run_context_minimal, reason="success")
    assert result.success
    assert result.payload["skipped"] is True


def test_teardown_keep_containers_false_executes_cleanup(run_context_minimal: Any) -> None:
    def fake_run(self: Any, command: str, timeout: float | None = None) -> CommandResult:
        return _ok()

    with patch("bench.remote.ssh.SSHRemoteSession.run", new=fake_run):
        result = run_teardown_stage(run_context_minimal, reason="failure")
    assert result.success
    assert result.payload["failed_hosts"] == []


def test_teardown_called_on_success_and_failure_paths(tmp_path) -> None:
    from pathlib import Path
    from bench.context import BenchParams
    from bench.orchestrator import run_pipeline

    cfg = Path(tmp_path) / "config.cfg"
    keys = Path(tmp_path) / "keys"
    keys.mkdir(parents=True, exist_ok=True)
    (keys / "host1").write_text("k", encoding="utf-8")
    (keys / "host2").write_text("k", encoding="utf-8")
    cfg.write_text(
        "host1_ip=1\nhost2_ip=2\nhost1_key_path=keys/host1\nhost2_key_path=keys/host2\nhost1_ssh_hostname=h1\nhost2_ssh_hostname=h2\n",
        encoding="utf-8",
    )

    with (
        patch("bench.orchestrator.run_preflight_stage", return_value=StageResult(success=True)),
        patch("bench.orchestrator.run_cleanup_stage", return_value=StageResult(success=True)),
        patch("bench.orchestrator.run_deploy_stage", return_value=StageResult(success=True)),
        patch("bench.orchestrator.run_benchmark_stage", return_value=StageResult(success=True)),
        patch("bench.orchestrator.run_metrics_stage", return_value=StageResult(success=True)),
        patch("bench.orchestrator.run_results_stage", return_value=StageResult(success=True)),
        patch("bench.orchestrator.run_teardown_stage", return_value=StageResult(success=True)) as td,
    ):
        run_pipeline(tmp_path, cfg, BenchParams())
    assert td.called
