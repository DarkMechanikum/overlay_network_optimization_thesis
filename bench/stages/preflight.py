from __future__ import annotations

from dataclasses import dataclass

from bench.context import RunContext, StageResult
from bench.remote.ssh import CommandResult, SSHRemoteSession
from bench.runtime.failures import failure_payload


@dataclass(frozen=True)
class DependencySpec:
    name: str
    command: str
    hard_fail: bool


DEPENDENCIES: tuple[DependencySpec, ...] = (
    DependencySpec(name="host_probe", command="uname -a", hard_fail=True),
    DependencySpec(name="docker_version", command="docker --version", hard_fail=True),
    DependencySpec(name="docker_info", command="docker info", hard_fail=True),
    DependencySpec(name="metric_tool", command="command -v mpstat || command -v pidstat", hard_fail=False),
    DependencySpec(name="python3", command="python3 --version", hard_fail=True),
    DependencySpec(name="benchmark_tool", command="command -v iperf3", hard_fail=False),
)


def _run_dependency_check(session: SSHRemoteSession, spec: DependencySpec, timeout: float) -> dict[str, object]:
    result: CommandResult = session.run(spec.command, timeout=timeout)
    return {
        "name": spec.name,
        "hard_fail": spec.hard_fail,
        "ok": result.ok,
        "returncode": result.returncode,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
    }


def run_preflight_stage(ctx: RunContext) -> StageResult:
    host_reports: dict[str, object] = {}
    hard_failures: list[str] = []

    for host in (ctx.host1, ctx.host2):
        session = SSHRemoteSession(host)
        checks: list[dict[str, object]] = []
        for spec in DEPENDENCIES:
            check = _run_dependency_check(session, spec, timeout=ctx.bench_params.ssh_timeout_seconds)
            checks.append(check)
            if spec.hard_fail and not check["ok"]:
                hard_failures.append(f"{host.role}:{spec.name}")

        host_reports[host.role] = {
            "host": host.ssh_hostname,
            "checks": checks,
            "hard_failures": [c["name"] for c in checks if c["hard_fail"] and not c["ok"]],
            "soft_failures": [c["name"] for c in checks if (not c["hard_fail"]) and (not c["ok"])],
        }

    if hard_failures:
        return StageResult(
            success=False,
            message="Preflight failed hard dependency checks",
            payload={"hosts": host_reports, "hard_failures": hard_failures, **failure_payload("dependency_check", "Preflight failed hard dependency checks", retryable=False)},
        )

    return StageResult(
        success=True,
        message="Preflight checks passed",
        payload={"hosts": host_reports, "hard_failures": []},
    )
