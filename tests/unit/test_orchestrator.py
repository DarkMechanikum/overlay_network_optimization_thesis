from __future__ import annotations

import time
from pathlib import Path
from unittest.mock import patch

from bench.context import BenchParams, StageResult
from bench.orchestrator import _run_stage_with_resilience, run_pipeline


def _config_with_keys(repo_root: Path) -> Path:
    keys_dir = repo_root / "keys"
    keys_dir.mkdir(parents=True, exist_ok=True)
    (keys_dir / "host1").write_text("k1", encoding="utf-8")
    (keys_dir / "host2").write_text("k2", encoding="utf-8")
    cfg = repo_root / "config.cfg"
    cfg.write_text(
        "\n".join(
            [
                "host1_ip=10.0.0.1",
                "host2_ip=10.0.0.2",
                "host1_key_path=keys/host1",
                "host2_key_path=keys/host2",
                "host1_ssh_hostname=host1.local",
                "host2_ssh_hostname=host2.local",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    return cfg


def test_orchestrator_success_order_includes_results_then_teardown(tmp_path: Path) -> None:
    order: list[str] = []
    cfg = _config_with_keys(tmp_path)

    def preflight(ctx):
        order.append("preflight")
        return StageResult(success=True, message="ok")

    def cleanup(ctx):
        order.append("cleanup")
        return StageResult(success=True, message="ok")

    def deploy(ctx):
        order.append("deploy")
        return StageResult(success=True, message="ok")

    def benchmark(ctx):
        order.append("benchmark")
        return StageResult(success=True, message="ok")

    def metrics(ctx):
        order.append("metrics")
        return StageResult(success=True, message="ok")

    def results(ctx):
        order.append("results")
        return StageResult(success=True, message="ok")

    def teardown(ctx, reason):
        order.append("teardown")
        return StageResult(success=True, message="ok")

    with (
        patch("bench.orchestrator.run_preflight_stage", side_effect=preflight),
        patch("bench.orchestrator.run_cleanup_stage", side_effect=cleanup),
        patch("bench.orchestrator.run_deploy_stage", side_effect=deploy),
        patch("bench.orchestrator.run_benchmark_stage", side_effect=benchmark),
        patch("bench.orchestrator.run_metrics_stage", side_effect=metrics),
        patch("bench.orchestrator.run_results_stage", side_effect=results),
        patch("bench.orchestrator.run_teardown_stage", side_effect=teardown),
    ):
        run_pipeline(tmp_path, cfg, BenchParams())

    assert order == ["preflight", "cleanup", "deploy", "benchmark", "metrics", "results", "teardown"]


def test_orchestrator_stops_on_non_retryable_failure(tmp_path: Path) -> None:
    order: list[str] = []
    cfg = _config_with_keys(tmp_path)

    def preflight(ctx):
        order.append("preflight")
        return StageResult(success=True, message="ok")

    def cleanup(ctx):
        order.append("cleanup")
        return StageResult(success=False, message="cleanup failed", payload={"retryable": False})

    def teardown(ctx, reason):
        order.append("teardown")
        return StageResult(success=True, message="ok")

    with (
        patch("bench.orchestrator.run_preflight_stage", side_effect=preflight),
        patch("bench.orchestrator.run_cleanup_stage", side_effect=cleanup),
        patch("bench.orchestrator.run_teardown_stage", side_effect=teardown),
    ):
        ctx = run_pipeline(tmp_path, cfg, BenchParams())

    assert order == ["preflight", "cleanup", "teardown"]
    assert not ctx.stage_results["cleanup"].success


def test_orchestrator_retries_transient_failure_then_success(tmp_path: Path) -> None:
    order: list[str] = []
    cfg = _config_with_keys(tmp_path)
    attempts = {"deploy": 0}

    def ok(stage):
        def _fn(ctx):
            order.append(stage)
            return StageResult(success=True, message="ok")

        return _fn

    def deploy(ctx):
        order.append("deploy")
        attempts["deploy"] += 1
        if attempts["deploy"] == 1:
            return StageResult(success=False, message="transient ssh timeout", payload={"retryable": True})
        return StageResult(success=True, message="ok")

    with (
        patch("bench.orchestrator.run_preflight_stage", side_effect=ok("preflight")),
        patch("bench.orchestrator.run_cleanup_stage", side_effect=ok("cleanup")),
        patch("bench.orchestrator.run_deploy_stage", side_effect=deploy),
        patch("bench.orchestrator.run_benchmark_stage", side_effect=ok("benchmark")),
        patch("bench.orchestrator.run_metrics_stage", side_effect=ok("metrics")),
        patch("bench.orchestrator.run_results_stage", side_effect=ok("results")),
        patch("bench.orchestrator.run_teardown_stage", return_value=StageResult(success=True, message="ok")),
    ):
        ctx = run_pipeline(tmp_path, cfg, BenchParams(retries=1, retry_backoff_seconds=0))

    assert ctx.stage_results["deploy"].success
    assert attempts["deploy"] == 2


def test_orchestrator_retries_exhausted_path(tmp_path: Path) -> None:
    cfg = _config_with_keys(tmp_path)

    with (
        patch("bench.orchestrator.run_preflight_stage", return_value=StageResult(success=False, message="ssh timeout", payload={"retryable": True})),
        patch("bench.orchestrator.run_teardown_stage", return_value=StageResult(success=True, message="ok")),
    ):
        ctx = run_pipeline(tmp_path, cfg, BenchParams(retries=2, retry_backoff_seconds=0))

    assert not ctx.stage_results["preflight"].success


def test_orchestrator_does_not_retry_without_explicit_retryable(tmp_path: Path) -> None:
    cfg = _config_with_keys(tmp_path)
    calls = {"count": 0}

    def failing(ctx):
        calls["count"] += 1
        return StageResult(success=False, message="some failure", payload={})

    with (
        patch("bench.orchestrator.run_preflight_stage", side_effect=failing),
        patch("bench.orchestrator.run_teardown_stage", return_value=StageResult(success=True, message="ok")),
    ):
        ctx = run_pipeline(tmp_path, cfg, BenchParams(retries=3, retry_backoff_seconds=0))

    assert not ctx.stage_results["preflight"].success
    assert calls["count"] == 1


def test_stage_timeout_path_marks_failure() -> None:
    def slow_stage(ctx):
        time.sleep(0.02)
        return StageResult(success=True, message="ok")

    ctx = type("C", (), {"bench_params": BenchParams(stage_timeout_seconds=0.001, retries=0)})()
    result = _run_stage_with_resilience(ctx, "x", slow_stage)
    assert not result.success
    assert "timed out" in result.message
    assert result.payload["failure"]["kind"] == "timeout"
    assert result.payload["retryable"] is True


def test_stage_timeout_is_preemptive() -> None:
    def very_slow_stage(ctx):
        time.sleep(0.2)
        return StageResult(success=True, message="ok")

    ctx = type("C", (), {"bench_params": BenchParams(stage_timeout_seconds=0.01, retries=0)})()
    started = time.monotonic()
    result = _run_stage_with_resilience(ctx, "x", very_slow_stage)
    elapsed = time.monotonic() - started
    assert not result.success
    assert elapsed < 0.1


def test_interrupt_path_triggers_teardown(tmp_path: Path) -> None:
    cfg = _config_with_keys(tmp_path)

    with (
        patch("bench.orchestrator.run_preflight_stage", side_effect=KeyboardInterrupt()),
        patch("bench.orchestrator.run_teardown_stage", return_value=StageResult(success=True, message="ok")) as teardown,
    ):
        ctx = run_pipeline(tmp_path, cfg, BenchParams())

    assert "orchestrator" in ctx.stage_results
    teardown.assert_called_once()


def test_dry_run_wiring_path(tmp_path: Path) -> None:
    cfg = _config_with_keys(tmp_path)
    with patch("bench.orchestrator.run_teardown_stage", return_value=StageResult(success=True, message="ok")):
        ctx = run_pipeline(tmp_path, cfg, BenchParams(dry_run=True))

    for stage in ("preflight", "cleanup", "deploy", "benchmark", "metrics", "results"):
        assert ctx.stage_results[stage].success
        assert ctx.stage_results[stage].payload.get("dry_run") is True
