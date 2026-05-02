from __future__ import annotations

from unittest.mock import patch

from bench.cli import build_parser, main
from bench.context import StageResult


def test_cli_defaults_for_new_flags() -> None:
    args = build_parser().parse_args([])
    assert args.retries == 0
    assert args.timeout == 120.0
    assert args.keep_containers is False
    assert args.dry_run is False
    assert args.cpu_window_seconds == 0.01
    assert args.allow_synthetic_telemetry is False


def test_cli_overrides_for_new_flags() -> None:
    args = build_parser().parse_args(
        ["--retries", "2", "--timeout", "44", "--keep-containers", "--dry-run", "--cpu-window-seconds", "0.05", "--allow-synthetic-telemetry"]
    )
    assert args.retries == 2
    assert args.timeout == 44.0
    assert args.keep_containers is True
    assert args.dry_run is True
    assert args.cpu_window_seconds == 0.05
    assert args.allow_synthetic_telemetry is True


def test_main_exit_code_success_and_failure_summary(capsys) -> None:
    ok_ctx = type("Ctx", (), {"stage_results": {"results": StageResult(success=True, payload={"result_csv_path": "a.csv"})}})()
    bad_ctx = type(
        "Ctx",
        (),
        {"stage_results": {"deploy": StageResult(success=False, message="ssh timeout"), "teardown": StageResult(success=True)}},
    )()

    with patch("bench.cli.run_pipeline", return_value=ok_ctx):
        assert main(["--dry-run"]) == 0

    with patch("bench.cli.run_pipeline", return_value=bad_ctx):
        assert main(["--dry-run"]) == 2
    output = capsys.readouterr().out
    assert "FAILED stage: deploy" in output
    assert "Hint:" in output


def test_main_validation_failure_is_deterministic(capsys) -> None:
    # warmup+cooldown must be strictly less than duration
    rc = main(["--duration-seconds", "4", "--warmup-seconds", "2", "--cooldown-seconds", "2"])
    assert rc == 2
    output = capsys.readouterr().out
    assert "Parameter validation failed:" in output
    assert "duration_seconds" in output


def test_main_validation_failure_short_circuits_pipeline() -> None:
    with patch("bench.cli.run_pipeline") as run_pipeline:
        rc = main(["--retries", "-1"])
    assert rc == 2
    run_pipeline.assert_not_called()
