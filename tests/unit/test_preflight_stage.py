from __future__ import annotations

from typing import Any
from unittest.mock import patch

from bench.remote.ssh import CommandResult
from bench.stages.preflight import run_preflight_stage


def _result_for_command(command: str, role: str) -> CommandResult:
    if command == "docker --version" and role == "host2":
        return CommandResult(argv=["ssh"], returncode=1, stdout="", stderr="docker missing")
    if command == "command -v mpstat || command -v pidstat" and role == "host1":
        return CommandResult(argv=["ssh"], returncode=1, stdout="", stderr="metrics tool missing")
    return CommandResult(argv=["ssh"], returncode=0, stdout="ok", stderr="")


def test_dependency_checks_hard_fail_vs_soft_fail(run_context_minimal: Any) -> None:
    role_lookup = {
        run_context_minimal.host1.ssh_hostname: run_context_minimal.host1.role,
        run_context_minimal.host2.ssh_hostname: run_context_minimal.host2.role,
    }

    def fake_run(self: Any, command: str, timeout: float | None = None) -> CommandResult:
        role = role_lookup[self.host.ssh_hostname]
        return _result_for_command(command, role)

    with patch("bench.remote.ssh.SSHRemoteSession.run", new=fake_run):
        result = run_preflight_stage(run_context_minimal)

    assert not result.success
    assert "host2:docker_version" in result.payload["hard_failures"]
    assert result.payload["retryable"] is False
    assert result.payload["failure"]["kind"] == "dependency_check"
    host1_report = result.payload["hosts"]["host1"]
    assert "metric_tool" in host1_report["soft_failures"]


def test_preflight_report_aggregates_per_host(run_context_minimal: Any) -> None:
    def fake_ok_run(self: Any, command: str, timeout: float | None = None) -> CommandResult:
        return CommandResult(argv=["ssh"], returncode=0, stdout=f"{self.host.role}:{command}", stderr="")

    with patch("bench.remote.ssh.SSHRemoteSession.run", new=fake_ok_run):
        result = run_preflight_stage(run_context_minimal)

    assert result.success
    assert result.payload["hard_failures"] == []
    assert set(result.payload["hosts"].keys()) == {"host1", "host2"}
    for report in result.payload["hosts"].values():
        assert len(report["checks"]) >= 4
