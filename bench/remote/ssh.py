from __future__ import annotations

import subprocess
from dataclasses import dataclass
from typing import Sequence

from bench.context import HostConfig


@dataclass(frozen=True)
class CommandResult:
    argv: list[str]
    returncode: int
    stdout: str
    stderr: str
    timed_out: bool = False
    retryable: bool = False

    @property
    def ok(self) -> bool:
        return self.returncode == 0


class SSHRemoteSession:
    def __init__(self, host: HostConfig) -> None:
        self.host = host

    def build_ssh_argv(self, command: str | Sequence[str], timeout: float | None = None) -> list[str]:
        if isinstance(command, str):
            remote_command = command
        else:
            remote_command = " ".join(command)

        argv = [
            "ssh",
            "-i",
            str(self.host.key_path),
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=accept-new",
            self.host.ssh_hostname,
            "--",
            remote_command,
        ]
        if timeout is not None:
            argv[1:1] = ["-o", f"ConnectTimeout={int(timeout)}"]
        return argv

    def run(self, command: str | Sequence[str], *, timeout: float | None = None) -> CommandResult:
        argv = self.build_ssh_argv(command, timeout=timeout)
        try:
            completed = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
            return CommandResult(
                argv=argv,
                returncode=completed.returncode,
                stdout=completed.stdout,
                stderr=completed.stderr,
                timed_out=False,
                retryable=False,
            )
        except subprocess.TimeoutExpired as exc:
            stdout = exc.stdout or ""
            stderr = exc.stderr or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode("utf-8", errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode("utf-8", errors="replace")
            return CommandResult(
                argv=argv,
                returncode=124,
                stdout=stdout,
                stderr=stderr + "\nCommand timed out",
                timed_out=True,
                retryable=True,
            )
