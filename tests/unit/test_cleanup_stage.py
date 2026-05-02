from __future__ import annotations

from dataclasses import replace
from typing import Any
from unittest.mock import patch

from bench.remote.ssh import CommandResult
from bench.stages.cleanup import build_cleanup_plan, run_cleanup_stage


def _ok(command: str, stdout: str = "") -> CommandResult:
    return CommandResult(argv=["ssh", command], returncode=0, stdout=stdout, stderr="")


def _fake_cleanup_run(command_log: list[str], fail_health_for: str | None = None):
    def _runner(self: Any, command: str, timeout: float | None = None) -> CommandResult:
        command_log.append(f"{self.host.role}:{command}")
        if fail_health_for == self.host.role and command == "docker ps --format '{{.ID}}'":
            return CommandResult(argv=["ssh"], returncode=1, stdout="", stderr="daemon down")
        if command == "uname -r":
            return _ok(command, "6.1.0-test")
        if command == "docker --version":
            return _ok(command, "Docker version 25.0.2, build deadbeef")
        if command == "nproc":
            return _ok(command, "16")
        if command == "df -Pk /":
            return _ok(command, "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 100 90 10 90% /")
        if command == "awk '/MemAvailable/ {print $2}' /proc/meminfo":
            return _ok(command, "400000")
        return _ok(command, "")

    return _runner


def test_safe_mode_uses_benchmark_scoped_commands(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(
        run_context_minimal.bench_params,
        cleanup_mode="safe",
        confirm_full_cleanup=False,
    )
    command_log: list[str] = []

    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_fake_cleanup_run(command_log)):
        result = run_cleanup_stage(run_context_minimal)

    assert result.success
    host1_plan = result.payload["hosts"]["host1"]["planned_commands"]
    assert any("label=overlay.bench=true" in cmd for cmd in host1_plan)
    assert not any("docker system prune -af --volumes" in cmd for cmd in host1_plan)


def test_full_mode_requires_confirmation(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(
        run_context_minimal.bench_params,
        cleanup_mode="full",
        confirm_full_cleanup=False,
    )

    result = run_cleanup_stage(run_context_minimal)

    assert not result.success
    assert "requires explicit" in result.message


def test_idempotent_cleanup_and_command_order(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(run_context_minimal.bench_params, cleanup_mode="safe")
    command_log: list[str] = []

    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_fake_cleanup_run(command_log)):
        first = run_cleanup_stage(run_context_minimal)
        second = run_cleanup_stage(run_context_minimal)

    assert first.success and second.success
    host1_commands = [c.split(":", 1)[1] for c in command_log if c.startswith("host1:")]
    first_docker_ps_index = host1_commands.index("docker ps --format '{{.ID}}'")
    first_mkdir_index = host1_commands.index("mkdir -p /tmp/bench-run /tmp/bench-run/logs /tmp/bench-run/work")
    assert first_mkdir_index < first_docker_ps_index


def test_docker_health_failure_is_hard_fail(run_context_minimal: Any) -> None:
    command_log: list[str] = []

    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_fake_cleanup_run(command_log, fail_health_for="host2")):
        result = run_cleanup_stage(run_context_minimal)

    assert not result.success
    assert "host2" in result.payload["hard_failures"]


def test_baseline_metadata_and_warnings(run_context_minimal: Any) -> None:
    command_log: list[str] = []

    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_fake_cleanup_run(command_log)):
        result = run_cleanup_stage(run_context_minimal)

    host1 = result.payload["hosts"]["host1"]
    assert host1["baseline"]["kernel_version"] == "6.1.0-test"
    assert host1["baseline"]["cpu_cores"] == 16
    assert host1["baseline"]["docker_version"].startswith("Docker version")
    assert any("disk usage is high" in w for w in host1["warnings"])
    assert any("available memory is low" in w for w in host1["warnings"])


def test_result_structure_contains_expected_fields(run_context_minimal: Any) -> None:
    command_log: list[str] = []

    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_fake_cleanup_run(command_log)):
        result = run_cleanup_stage(run_context_minimal)

    host2 = result.payload["hosts"]["host2"]
    assert {"planned_commands", "executed_commands", "health", "baseline", "warnings", "errors"} <= set(host2.keys())
    assert isinstance(host2["executed_commands"], list)
    assert "docker_ok" in host2["health"]


def test_build_cleanup_plan_full_contains_global_prune() -> None:
    plan = build_cleanup_plan("full", "/tmp/bench-run")
    assert "docker system prune -af --volumes" in plan.planned_commands
