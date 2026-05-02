from __future__ import annotations

from dataclasses import replace
from typing import Any
from unittest.mock import patch

from bench.remote.ssh import CommandResult
from bench.stages.deploy import build_container_name, build_deployment_commands, run_deploy_stage


def _ok(command: str, stdout: str = "") -> CommandResult:
    return CommandResult(argv=["ssh", command], returncode=0, stdout=stdout, stderr="")


def _deploy_runner_factory(command_log: list[str], fail_readiness: bool = False):
    readiness_counter: dict[str, int] = {}

    def _runner(self: Any, command: str, timeout: float | None = None) -> CommandResult:
        command_log.append(f"{self.host.role}:{command}")
        if command.startswith("docker inspect -f '{{.State.Status}}' "):
            name = command.rsplit(" ", 1)[-1]
            readiness_counter[name] = readiness_counter.get(name, 0) + 1
            if fail_readiness:
                return _ok(command, "starting")
            if readiness_counter[name] == 1:
                return _ok(command, "starting")
            return _ok(command, "running")
        if command.startswith("docker ps -aqf name="):
            name = command.split("^", 1)[1].rstrip("$")
            return _ok(command, f"cid-{name}")
        if command.startswith("docker inspect -f '{{.Image}}' "):
            return _ok(command, "sha256:abc123")
        return _ok(command, "")

    return _runner


def test_mode_selector_outputs_expected_paths() -> None:
    remote = build_deployment_commands("remote-build", "img:1", "/tmp/i.tar")
    transfer = build_deployment_commands("transfer", "img:1", "/tmp/i.tar")
    assert remote["remote"] == ["docker build -t img:1 ."]
    assert transfer["local"] == ["docker save -o /tmp/i.tar img:1"]
    assert "scp /tmp/i.tar {host}:/tmp/i.tar" in transfer["remote"]


def test_transfer_mode_emits_save_transfer_load_sequence(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(
        run_context_minimal.bench_params,
        deployment_mode="transfer",
        image_tag="overlay-bench:test",
        local_image_archive="/tmp/image.tar",
    )
    command_log: list[str] = []
    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_deploy_runner_factory(command_log)):
        result = run_deploy_stage(run_context_minimal)

    assert result.success
    assert result.payload["local_actions"] == ["docker save -o /tmp/image.tar overlay-bench:test"]
    host1_cmds = [x["command"] for x in result.payload["hosts"]["host1"]["deployment_actions"]]
    assert "scp /tmp/image.tar h1.local:/tmp/image.tar" in host1_cmds
    assert "docker load -i /tmp/image.tar" in host1_cmds


def test_remote_build_mode_emits_build_on_each_host(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(
        run_context_minimal.bench_params,
        deployment_mode="remote-build",
        image_tag="overlay-bench:test",
    )
    command_log: list[str] = []
    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_deploy_runner_factory(command_log)):
        result = run_deploy_stage(run_context_minimal)

    assert result.success
    host1_cmds = [x["command"] for x in result.payload["hosts"]["host1"]["deployment_actions"]]
    host2_cmds = [x["command"] for x in result.payload["hosts"]["host2"]["deployment_actions"]]
    assert "docker build -t overlay-bench:test ." in host1_cmds
    assert "docker build -t overlay-bench:test ." in host2_cmds


def test_startup_order_and_naming(run_context_minimal: Any) -> None:
    command_log: list[str] = []
    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_deploy_runner_factory(command_log)):
        result = run_deploy_stage(run_context_minimal)

    sequence = result.payload["startup_sequence"]
    assert [item["role"] for item in sequence] == ["receiver", "sender"]
    assert sequence[0]["container_name"] == build_container_name(run_context_minimal.run_id, "host2", "receiver")
    assert sequence[1]["container_name"] == build_container_name(run_context_minimal.run_id, "host1", "sender")


def test_readiness_retries_then_success(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(
        run_context_minimal.bench_params,
        readiness_timeout_seconds=4.0,
        readiness_poll_interval_seconds=2.0,
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
    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_deploy_runner_factory(command_log)):
        result = run_deploy_stage(run_context_minimal, clock=fake.now, sleeper=fake.sleep)

    assert result.success
    for readiness in result.payload["readiness"].values():
        assert readiness["ready"] is True
        assert readiness["attempt_count"] >= 2
        assert readiness["terminal_reason"] == "success"
    assert sleep_calls == [2.0, 2.0]


def test_readiness_timeout_returns_failure(run_context_minimal: Any) -> None:
    run_context_minimal.bench_params = replace(
        run_context_minimal.bench_params,
        readiness_timeout_seconds=3.0,
        readiness_poll_interval_seconds=1.0,
    )
    command_log: list[str] = []
    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_deploy_runner_factory(command_log, fail_readiness=True)):
        result = run_deploy_stage(run_context_minimal)

    assert not result.success
    assert sorted(result.payload["hard_failures"]) == ["host1", "host2"]
    assert result.payload["retryable"] is True
    assert result.payload["failure"]["kind"] == "deployment"
    assert "not ready before timeout" in " ".join(result.payload["hosts"]["host1"]["errors"])


def test_metadata_capture_contains_image_and_container_identifiers(run_context_minimal: Any) -> None:
    command_log: list[str] = []
    with patch("bench.remote.ssh.SSHRemoteSession.run", new=_deploy_runner_factory(command_log)):
        result = run_deploy_stage(run_context_minimal)

    host1_meta = result.payload["metadata"]["hosts"]["host1"]
    assert host1_meta["container_name"] == f"bench-{run_context_minimal.run_id}-host1-sender"
    assert host1_meta["container_id"].startswith("cid-")
    assert host1_meta["image_identifier"] == "sha256:abc123"
