from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from bench.context import RunContext, StageResult
from bench.remote.ssh import SSHRemoteSession


@dataclass(frozen=True)
class HostCleanupPlan:
    planned_commands: list[str]
    temp_dirs: list[str]


def _safe_cleanup_commands(temp_root: str) -> list[str]:
    return [
        "docker ps -aq --filter label=overlay.bench=true | xargs -r docker rm -f",
        "docker images -q --filter label=overlay.bench=true | xargs -r docker rmi -f",
        f"rm -rf {temp_root}-*",
    ]


def _full_cleanup_commands(temp_root: str) -> list[str]:
    return [
        "docker system prune -af --volumes",
        f"rm -rf {temp_root}-*",
    ]


def build_cleanup_plan(mode: str, temp_root: str) -> HostCleanupPlan:
    temp_dirs = [temp_root, f"{temp_root}/logs", f"{temp_root}/work"]
    if mode == "safe":
        return HostCleanupPlan(planned_commands=_safe_cleanup_commands(temp_root), temp_dirs=temp_dirs)
    if mode == "full":
        return HostCleanupPlan(planned_commands=_full_cleanup_commands(temp_root), temp_dirs=temp_dirs)
    raise ValueError(f"Unsupported cleanup mode: {mode}")


def _parse_disk_use_percent(df_stdout: str) -> int | None:
    lines = [line for line in df_stdout.strip().splitlines() if line.strip()]
    if len(lines) < 2:
        return None
    parts = lines[1].split()
    if len(parts) < 5:
        return None
    usage = parts[4].rstrip("%")
    return int(usage) if usage.isdigit() else None


def _parse_int(stdout: str) -> int | None:
    token = stdout.strip().splitlines()[0] if stdout.strip() else ""
    return int(token) if token.isdigit() else None


def _run(session: SSHRemoteSession, command: str, timeout: float) -> dict[str, Any]:
    result = session.run(command, timeout=timeout)
    return {
        "command": command,
        "ok": result.ok,
        "returncode": result.returncode,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
    }


def run_cleanup_stage(ctx: RunContext) -> StageResult:
    """
    Prepare a deterministic host baseline before deploy.

    Hard fail conditions:
    - full cleanup requested without explicit confirmation
    - docker post-cleanup health checks fail
    """

    params = ctx.bench_params
    if params.cleanup_mode == "full" and not params.confirm_full_cleanup:
        return StageResult(
            success=False,
            message="Full cleanup mode requires explicit --confirm-full-cleanup",
            payload={"hosts": {}, "errors": ["full cleanup requested without confirmation"]},
        )

    plan = build_cleanup_plan(params.cleanup_mode, params.host_temp_root)
    hosts_payload: dict[str, Any] = {}
    hard_failures: list[str] = []

    for host in (ctx.host1, ctx.host2):
        session = SSHRemoteSession(host)
        executed: list[dict[str, Any]] = []
        warnings: list[str] = []
        errors: list[str] = []

        for command in plan.planned_commands:
            command_result = _run(session, command, timeout=params.ssh_timeout_seconds)
            executed.append(command_result)
            if not command_result["ok"]:
                warnings.append(f"cleanup command returned non-zero: {command}")

        mkdir_cmd = f"mkdir -p {' '.join(plan.temp_dirs)}"
        mkdir_result = _run(session, mkdir_cmd, timeout=params.ssh_timeout_seconds)
        executed.append(mkdir_result)
        if not mkdir_result["ok"]:
            errors.append("failed to create host temp directories")

        health_checks = [
            _run(session, "docker ps --format '{{.ID}}'", timeout=params.ssh_timeout_seconds),
            _run(session, "docker images --format '{{.Repository}}:{{.Tag}}'", timeout=params.ssh_timeout_seconds),
        ]
        executed.extend(health_checks)
        health_ok = all(item["ok"] for item in health_checks)
        if not health_ok:
            hard_failures.append(host.role)
            errors.append("docker daemon health check failed")

        kernel = _run(session, "uname -r", timeout=params.ssh_timeout_seconds)
        docker_version = _run(session, "docker --version", timeout=params.ssh_timeout_seconds)
        cpu_count = _run(session, "nproc", timeout=params.ssh_timeout_seconds)
        disk = _run(session, "df -Pk /", timeout=params.ssh_timeout_seconds)
        mem_avail = _run(session, "awk '/MemAvailable/ {print $2}' /proc/meminfo", timeout=params.ssh_timeout_seconds)
        executed.extend([kernel, docker_version, cpu_count, disk, mem_avail])

        disk_percent = _parse_disk_use_percent(disk["stdout"])
        if disk_percent is not None and disk_percent >= params.disk_warn_percent:
            warnings.append(f"disk usage is high: {disk_percent}%")

        mem_kb = _parse_int(mem_avail["stdout"])
        if mem_kb is not None:
            mem_mb = mem_kb // 1024
            if mem_mb < params.memory_warn_mb:
                warnings.append(f"available memory is low: {mem_mb}MB")
        else:
            mem_mb = None

        hosts_payload[host.role] = {
            "host": host.ssh_hostname,
            "cleanup_mode": params.cleanup_mode,
            "planned_commands": plan.planned_commands + [mkdir_cmd],
            "executed_commands": executed,
            "actions_taken": [item["command"] for item in executed if item["ok"]],
            "health": {"docker_ok": health_ok},
            "baseline": {
                "kernel_version": kernel["stdout"],
                "docker_version": docker_version["stdout"],
                "cpu_cores": _parse_int(cpu_count["stdout"]),
                "disk_use_percent": disk_percent,
                "memory_available_mb": mem_mb,
                "temp_dirs": plan.temp_dirs,
            },
            "warnings": warnings,
            "errors": errors,
        }

    if hard_failures:
        return StageResult(
            success=False,
            message="Cleanup failed due to docker health checks",
            payload={"hosts": hosts_payload, "hard_failures": hard_failures},
        )

    return StageResult(
        success=True,
        message="Cleanup completed",
        payload={"hosts": hosts_payload, "hard_failures": []},
    )
