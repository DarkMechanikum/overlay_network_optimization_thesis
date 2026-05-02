from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import patch

from bench.context import HostConfig
from bench.remote.ssh import SSHRemoteSession


def test_ssh_argv_contains_identity_hostname_timeout(tmp_path: Path) -> None:
    key = tmp_path / "id_rsa"
    key.write_text("dummy", encoding="utf-8")
    host = HostConfig(role="host1", ip="10.0.0.1", ssh_hostname="host1.local", key_path=key)
    session = SSHRemoteSession(host)

    argv = session.build_ssh_argv("uname -a", timeout=9.0)

    assert argv[0] == "ssh"
    assert "-i" in argv
    assert str(key) in argv
    assert "host1.local" in argv
    assert "ConnectTimeout=9" in argv
    assert "BatchMode=yes" in argv
    assert "StrictHostKeyChecking=accept-new" in argv


def test_run_captures_stdout_stderr_exitcode(tmp_path: Path) -> None:
    key = tmp_path / "id_rsa"
    key.write_text("dummy", encoding="utf-8")
    host = HostConfig(role="host1", ip="10.0.0.1", ssh_hostname="host1.local", key_path=key)
    session = SSHRemoteSession(host)
    completed = subprocess.CompletedProcess(args=["ssh"], returncode=3, stdout="x", stderr="y")

    with patch("bench.remote.ssh.subprocess.run", return_value=completed) as run_mock:
        result = session.run("docker --version", timeout=4.0)

    run_mock.assert_called_once()
    assert result.returncode == 3
    assert result.stdout == "x"
    assert result.stderr == "y"
    assert result.timed_out is False
    assert result.retryable is False


def test_run_timeout_returns_retryable_timeout_result(tmp_path: Path) -> None:
    key = tmp_path / "id_rsa"
    key.write_text("dummy", encoding="utf-8")
    host = HostConfig(role="host1", ip="10.0.0.1", ssh_hostname="host1.local", key_path=key)
    session = SSHRemoteSession(host)
    timeout_exc = subprocess.TimeoutExpired(cmd=["ssh"], timeout=1.0, output=b"o", stderr=b"e")

    with patch("bench.remote.ssh.subprocess.run", side_effect=timeout_exc):
        result = session.run("docker --version", timeout=1.0)

    assert result.returncode == 124
    assert result.timed_out is True
    assert result.retryable is True
    assert result.stdout == "o"
    assert "timed out" in result.stderr.lower()
