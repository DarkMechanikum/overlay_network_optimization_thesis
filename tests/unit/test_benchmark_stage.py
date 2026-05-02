from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path
from typing import Any
from unittest.mock import patch

from bench.remote.ssh import CommandResult
from bench.stages.benchmark import benchmark_runtime_timeout_seconds, run_benchmark_stage


def _ok(command: str, stdout: str = "") -> CommandResult:
    return CommandResult(argv=["ssh", command], returncode=0, stdout=stdout, stderr="")


def _runner_factory(command_log: list[str], established_count: int):
    def _runner(self: Any, command: str, timeout: float | None = None) -> CommandResult:
        command_log.append(f"{self.host.role}:{command}")
        if "status.py" in command:
            return _ok(command, json.dumps({"established_count": established_count}))
        return _ok(command, "")

    return _runner


def _numeric_runner_factory(command_log: list[str], established_count: int):
    def _runner(self: Any, command: str, timeout: float | None = None) -> CommandResult:
        command_log.append(f"{self.host.role}:{command}")
        if "status.py" in command:
            return _ok(command, str(established_count))
        return _ok(command, "")

    return _runner


def test_runtime_status_full_success(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(run_context_minimal.bench_params, connections=3, base_pps=100)
    command_log: list[str] = []
    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_runner_factory(command_log, established_count=3)):
        result = run_benchmark_stage(run_context_minimal)

    assert result.success
    assert result.payload["requested_count"] == 3
    assert result.payload["established_count"] == 3
    assert all(item["status"] == "established" for item in result.payload["per_flow_status"])
    assert Path(result.payload["artifact_paths"]["flow_profile"]).exists()


def test_runtime_status_partial_establishment_failure(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(
        run_context_minimal.bench_params,
        connections=4,
        flow_startup_timeout_seconds=3.0,
        flow_startup_poll_interval_seconds=1.0,
    )
    command_log: list[str] = []
    sleep_calls: list[float] = []

    class _Clock:
        def __init__(self) -> None:
            self.value = 0.0

        def now(self) -> float:
            return self.value

        def sleep(self, seconds: float) -> None:
            sleep_calls.append(seconds)
            self.value += seconds

    fake = _Clock()
    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_runner_factory(command_log, established_count=2)):
        result = run_benchmark_stage(run_context_minimal, clock=fake.now, sleeper=fake.sleep)

    assert not result.success
    assert result.payload["requested_count"] == 4
    assert result.payload["established_count"] == 2
    assert any("partial flow establishment" in w for w in result.payload["warnings"])
    assert any(item["status"] == "not-established" for item in result.payload["per_flow_status"])
    assert result.payload["retryable"] is True
    assert result.payload["failure"]["kind"] == "flow_establishment"
    assert sleep_calls == [1.0, 1.0, 1.0]
    raw_status = json.loads(Path(result.payload["artifact_paths"]["raw_status"]).read_text(encoding="utf-8"))
    assert raw_status["polling"]["terminal_reason"] == "max_attempts_exhausted"


def test_stage_result_structure_contains_required_fields(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(run_context_minimal.bench_params, connections=2)
    command_log: list[str] = []
    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_runner_factory(command_log, established_count=2)):
        result = run_benchmark_stage(run_context_minimal)

    assert {
        "requested_count",
        "established_count",
        "per_flow_status",
        "artifact_paths",
        "warnings",
        "errors",
        "startup_sequence",
    } <= set(result.payload.keys())
    assert [item["role"] for item in result.payload["startup_sequence"]] == ["receiver", "sender"]
    assert "flow_profile" in result.payload["artifact_paths"]


def test_profile_target_pps_sequence_from_stage_artifact(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(run_context_minimal.bench_params, connections=5, base_pps=42)
    command_log: list[str] = []
    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_runner_factory(command_log, established_count=5)):
        result = run_benchmark_stage(run_context_minimal)

    profile_path = Path(result.payload["artifact_paths"]["flow_profile"])
    raw = json.loads(profile_path.read_text(encoding="utf-8"))
    pps = [entry["target_pps"] for entry in raw["flows"]]
    assert pps == [42, 43, 44, 45, 46]


def test_runtime_timeout_derivation_applied_to_benchmark_commands(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(
        run_context_minimal.bench_params,
        connections=1,
        ssh_timeout_seconds=5.0,
        warmup_seconds=2,
        duration_seconds=20,
        cooldown_seconds=3,
    )
    seen_timeouts: list[float] = []

    def _runner(self: Any, command: str, timeout: float | None = None) -> CommandResult:
        if command.startswith("docker exec") and timeout is not None:
            seen_timeouts.append(timeout)
        if "status.py" in command:
            return _ok(command, json.dumps({"established_count": 1}))
        return _ok(command, "")

    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_runner):
        result = run_benchmark_stage(run_context_minimal)

    assert result.success
    expected = benchmark_runtime_timeout_seconds(
        ssh_timeout_seconds=5.0, warmup_seconds=2, duration_seconds=20, cooldown_seconds=3
    )
    assert expected == 35.0
    assert len(seen_timeouts) >= 2
    assert all(t == expected for t in seen_timeouts[:2])


def test_synthetic_telemetry_disabled_fails_numeric_fallback(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(
        run_context_minimal.bench_params,
        connections=2,
        allow_synthetic_telemetry=False,
    )
    command_log: list[str] = []
    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_numeric_runner_factory(command_log, established_count=2)):
        result = run_benchmark_stage(run_context_minimal)

    assert not result.success
    assert any("synthetic fallback disabled" in err for err in result.payload["errors"])
    assert result.payload["synthetic_telemetry"] is False
    assert result.payload["telemetry_source"] == "runtime"


def test_synthetic_telemetry_enabled_marks_payload(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(
        run_context_minimal.bench_params,
        connections=2,
        allow_synthetic_telemetry=True,
    )
    command_log: list[str] = []
    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_numeric_runner_factory(command_log, established_count=2)):
        result = run_benchmark_stage(run_context_minimal)

    assert result.success
    assert result.payload["synthetic_telemetry"] is True
    assert result.payload["telemetry_source"] == "synthetic"
    assert any("synthetic latency samples" in w for w in result.payload["warnings"])
