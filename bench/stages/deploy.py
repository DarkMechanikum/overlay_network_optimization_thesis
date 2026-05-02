from __future__ import annotations

from dataclasses import dataclass
import time
from typing import Any

from bench.context import RunContext, StageResult
from bench.remote.ssh import SSHRemoteSession
from bench.runtime.failures import failure_payload
from bench.runtime.polling import poll_with_interval


@dataclass(frozen=True)
class ContainerSpec:
    host_role: str
    host_name: str
    container_name: str
    role: str


def build_container_name(run_id: str, host_role: str, role: str) -> str:
    return f"bench-{run_id}-{host_role}-{role}"


def build_deployment_commands(mode: str, image_tag: str, archive_path: str) -> dict[str, list[str]]:
    if mode == "remote-build":
        return {
            "local": [],
            "remote": [f"docker build -t {image_tag} ."],
        }
    if mode == "transfer":
        return {
            "local": [f"docker save -o {archive_path} {image_tag}"],
            "remote": [
                f"scp {archive_path} {{host}}:{archive_path}",
                f"docker load -i {archive_path}",
            ],
        }
    raise ValueError(f"Unsupported deployment mode: {mode}")


def _run(session: SSHRemoteSession, command: str, timeout: float) -> dict[str, Any]:
    result = session.run(command, timeout=timeout)
    return {
        "command": command,
        "ok": result.ok,
        "returncode": result.returncode,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
    }


def _inspect_readiness(stdout: str) -> bool:
    normalized = stdout.strip().lower()
    if not normalized:
        return False
    return normalized in {"running", "healthy", "true"}


def _readiness_attempts(timeout: float, poll_interval: float) -> int:
    if timeout <= 0:
        return 1
    if poll_interval <= 0:
        return 1
    return max(1, int(timeout // poll_interval) + 1)


def run_deploy_stage(
    ctx: RunContext,
    *,
    clock: Any = time.monotonic,
    sleeper: Any = time.sleep,
) -> StageResult:
    params = ctx.bench_params
    commands = build_deployment_commands(params.deployment_mode, params.image_tag, params.local_image_archive)

    host_specs = [
        ContainerSpec(
            host_role=ctx.host2.role,
            host_name=ctx.host2.ssh_hostname,
            container_name=build_container_name(ctx.run_id, ctx.host2.role, "receiver"),
            role="receiver",
        ),
        ContainerSpec(
            host_role=ctx.host1.role,
            host_name=ctx.host1.ssh_hostname,
            container_name=build_container_name(ctx.run_id, ctx.host1.role, "sender"),
            role="sender",
        ),
    ]
    host_lookup = {ctx.host1.role: ctx.host1, ctx.host2.role: ctx.host2}
    per_host: dict[str, Any] = {}
    local_actions: list[str] = []
    hard_failures: list[str] = []

    for local_cmd in commands["local"]:
        local_actions.append(local_cmd)

    for host in (ctx.host1, ctx.host2):
        session = SSHRemoteSession(host)
        executed: list[dict[str, Any]] = []
        errors: list[str] = []

        image_available = False
        for remote_cmd in commands["remote"]:
            expanded = remote_cmd.replace("{host}", host.ssh_hostname)
            command_result = _run(session, expanded, timeout=params.ssh_timeout_seconds)
            executed.append(command_result)
            if command_result["ok"]:
                image_available = True
            else:
                errors.append(f"deployment command failed: {expanded}")

        if not image_available:
            # Real-host fallback for environments without repository Dockerfile on remote hosts.
            pull_cmd = f"docker pull {params.fallback_runtime_image}"
            tag_cmd = f"docker tag {params.fallback_runtime_image} {params.image_tag}"
            pull_result = _run(session, pull_cmd, timeout=params.ssh_timeout_seconds)
            tag_result = _run(session, tag_cmd, timeout=params.ssh_timeout_seconds)
            executed.extend([pull_result, tag_result])
            if pull_result["ok"] and tag_result["ok"]:
                image_available = True
            else:
                errors.append(f"fallback runtime image setup failed using {params.fallback_runtime_image}")

        if errors and not image_available:
            hard_failures.append(host.role)

        per_host[host.role] = {
            "host": host.ssh_hostname,
            "deployment_mode": params.deployment_mode,
            "deployment_actions": executed,
            "warnings": [],
            "errors": errors,
        }

    startup_sequence: list[dict[str, Any]] = []
    for spec in host_specs:
        host = host_lookup[spec.host_role]
        session = SSHRemoteSession(host)
        run_cmd = (
            "docker run -d "
            f"--name {spec.container_name} "
            f"--network {params.container_network_mode} "
            f"--label overlay.bench=true "
            f"--label overlay.bench.run_id={ctx.run_id} "
            f"--label overlay.bench.role={spec.role} "
            f"{params.image_tag} "
            "sh -lc 'while true; do sleep 3600; done'"
        )
        started = _run(session, run_cmd, timeout=params.ssh_timeout_seconds)
        startup_sequence.append(
            {
                "host_role": spec.host_role,
                "role": spec.role,
                "container_name": spec.container_name,
                "start_result": started,
            }
        )
        per_host[spec.host_role]["deployment_actions"].append(started)
        if not started["ok"]:
            per_host[spec.host_role]["errors"].append(f"container start failed: {spec.container_name}")
            hard_failures.append(spec.host_role)

    readiness_results: dict[str, Any] = {}
    max_attempts = _readiness_attempts(
        timeout=params.readiness_timeout_seconds,
        poll_interval=params.readiness_poll_interval_seconds,
    )
    for spec in host_specs:
        host = host_lookup[spec.host_role]
        session = SSHRemoteSession(host)
        
        def _probe_once() -> tuple[bool, dict[str, Any]]:
            probe = _run(
                session,
                f"docker inspect -f '{{{{.State.Status}}}}' {spec.container_name}",
                timeout=params.ssh_timeout_seconds,
            )
            is_ready = probe["ok"] and _inspect_readiness(probe["stdout"])
            return is_ready, probe

        poll = poll_with_interval(
            max_attempts=max_attempts,
            interval_s=params.readiness_poll_interval_seconds,
            check_fn=_probe_once,
            clock=clock,
            sleeper=sleeper,
        )
        attempts = poll.values
        ready = poll.terminal_reason == "success"

        readiness_results[spec.container_name] = {
            "host_role": spec.host_role,
            "role": spec.role,
            "ready": ready,
            "attempt_count": poll.attempts,
            "max_attempts": max_attempts,
            "attempts": attempts,
            "timeout_seconds": params.readiness_timeout_seconds,
            "poll_interval_seconds": params.readiness_poll_interval_seconds,
            "elapsed_seconds": poll.elapsed_seconds,
            "terminal_reason": poll.terminal_reason,
        }
        per_host[spec.host_role]["deployment_actions"].extend(attempts)
        if not ready:
            per_host[spec.host_role]["errors"].append(f"container not ready before timeout: {spec.container_name}")
            hard_failures.append(spec.host_role)

    metadata: dict[str, Any] = {"image_tag": params.image_tag, "hosts": {}}
    for spec in host_specs:
        host = host_lookup[spec.host_role]
        session = SSHRemoteSession(host)
        cid = _run(session, f"docker ps -aqf name=^{spec.container_name}$", timeout=params.ssh_timeout_seconds)
        inspect_image = _run(
            session,
            f"docker inspect -f '{{{{.Image}}}}' {spec.container_name}",
            timeout=params.ssh_timeout_seconds,
        )
        per_host[spec.host_role]["deployment_actions"].extend([cid, inspect_image])
        metadata["hosts"][spec.host_role] = {
            "host": host.ssh_hostname,
            "container_role": spec.role,
            "container_name": spec.container_name,
            "container_id": cid["stdout"],
            "image_identifier": inspect_image["stdout"] or params.image_tag,
            "ready": readiness_results[spec.container_name]["ready"],
        }

    unique_failures = sorted(set(hard_failures))
    if unique_failures:
        return StageResult(
            success=False,
            message="Deploy stage failed",
            payload={
                "deployment_mode": params.deployment_mode,
                "local_actions": local_actions,
                "hosts": per_host,
                "startup_sequence": startup_sequence,
                "readiness": readiness_results,
                "metadata": metadata,
                "hard_failures": unique_failures,
                **failure_payload("deployment", "Deploy stage failed", retryable=True, hard_failures=unique_failures),
            },
        )

    return StageResult(
        success=True,
        message="Deploy stage completed",
        payload={
            "deployment_mode": params.deployment_mode,
            "local_actions": local_actions,
            "hosts": per_host,
            "startup_sequence": startup_sequence,
            "readiness": readiness_results,
            "metadata": metadata,
            "hard_failures": [],
        },
    )
