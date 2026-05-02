from __future__ import annotations

from pathlib import Path

import pytest

from bench.context import BenchParams, HostConfig, RunContext


@pytest.fixture
def repo_root(tmp_path: Path) -> Path:
    return tmp_path


@pytest.fixture
def host_configs(repo_root: Path) -> tuple[HostConfig, HostConfig]:
    key1 = repo_root / "keys" / "h1"
    key2 = repo_root / "keys" / "h2"
    key1.parent.mkdir(parents=True, exist_ok=True)
    key1.write_text("dummy", encoding="utf-8")
    key2.write_text("dummy", encoding="utf-8")
    return (
        HostConfig(role="host1", ip="10.0.0.1", ssh_hostname="h1.local", key_path=key1),
        HostConfig(role="host2", ip="10.0.0.2", ssh_hostname="h2.local", key_path=key2),
    )


@pytest.fixture
def run_context_minimal(repo_root: Path, host_configs: tuple[HostConfig, HostConfig]) -> RunContext:
    host1, host2 = host_configs
    return RunContext(
        repo_root=repo_root,
        host1=host1,
        host2=host2,
        bench_params=BenchParams(ssh_timeout_seconds=5.0),
        run_id="testrun",
        artifacts_root=repo_root / "artifacts" / "testrun",
    )
