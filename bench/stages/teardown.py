from __future__ import annotations

from typing import Any

from bench.context import RunContext, StageResult
from bench.remote.ssh import SSHRemoteSession


def _run(session: SSHRemoteSession, command: str, timeout: float) -> dict[str, Any]:
    result = session.run(command, timeout=timeout)
    return {
        "command": command,
        "ok": result.ok,
        "returncode": result.returncode,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
    }


def run_teardown_stage(ctx: RunContext, *, reason: str) -> StageResult:
    params = ctx.bench_params
    if params.dry_run:
        return StageResult(
            success=True,
            message="Teardown skipped in dry-run mode",
            payload={"skipped": True, "reason": reason, "dry_run": True},
        )
    if params.keep_containers:
        return StageResult(
            success=True,
            message="Teardown skipped because keep-containers is enabled",
            payload={"skipped": True, "reason": reason, "keep_containers": True},
        )

    commands = [
        "docker ps -aq --filter label=overlay.bench=true | xargs -r docker rm -f",
        "docker images -q --filter label=overlay.bench=true | xargs -r docker rmi -f",
    ]
    hosts_payload: dict[str, Any] = {}
    failures: list[str] = []
    for host in (ctx.host1, ctx.host2):
        session = SSHRemoteSession(host)
        executed = [_run(session, cmd, timeout=params.ssh_timeout_seconds) for cmd in commands]
        if not all(item["ok"] for item in executed):
            failures.append(host.role)
        hosts_payload[host.role] = {
            "host": host.ssh_hostname,
            "commands": executed,
        }

    if failures:
        return StageResult(
            success=False,
            message="Teardown completed with cleanup failures",
            payload={"reason": reason, "hosts": hosts_payload, "failed_hosts": failures},
        )
    return StageResult(
        success=True,
        message="Teardown completed",
        payload={"reason": reason, "hosts": hosts_payload, "failed_hosts": []},
    )
