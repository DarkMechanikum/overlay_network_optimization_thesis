from __future__ import annotations

from pathlib import Path

import pytest

from bench.config.loader import ConfigError, load_host_configs


def _write_cfg(path: Path, content: str) -> None:
    path.write_text(content.strip() + "\n", encoding="utf-8")


def test_parse_valid_config(repo_root: Path) -> None:
    key1 = repo_root / "keys" / "server1"
    key2 = repo_root / "keys" / "server2"
    key1.parent.mkdir(parents=True, exist_ok=True)
    key1.write_text("k1", encoding="utf-8")
    key2.write_text("k2", encoding="utf-8")
    cfg = repo_root / "config.cfg"
    _write_cfg(
        cfg,
        """
        host1_ip=192.168.0.1
        host2_ip=192.168.0.2
        host1_key_path=keys/server1
        host2_key_path=keys/server2
        host1_ssh_hostname=server1
        host2_ssh_hostname=server2
        """,
    )

    host1, host2 = load_host_configs(cfg, repo_root)
    assert host1.role == "host1"
    assert host1.ssh_hostname == "server1"
    assert host2.role == "host2"
    assert host2.ip == "192.168.0.2"


def test_missing_required_key_errors(repo_root: Path) -> None:
    cfg = repo_root / "config.cfg"
    _write_cfg(
        cfg,
        """
        host1_ip=1.1.1.1
        host1_key_path=keys/server1
        host2_key_path=keys/server2
        host1_ssh_hostname=server1
        host2_ssh_hostname=server2
        """,
    )

    with pytest.raises(ConfigError, match="host2_ip"):
        load_host_configs(cfg, repo_root)


def test_relative_key_path_resolution(repo_root: Path) -> None:
    key1 = repo_root / "keys" / "server1"
    key2 = repo_root / "keys" / "server2"
    key1.parent.mkdir(parents=True, exist_ok=True)
    key1.write_text("k1", encoding="utf-8")
    key2.write_text("k2", encoding="utf-8")
    cfg = repo_root / "config.cfg"
    _write_cfg(
        cfg,
        """
        host1_ip=1.1.1.1
        host2_ip=2.2.2.2
        host1_key_path=keys/server1
        host2_key_path=keys/server2
        host1_ssh_hostname=host1
        host2_ssh_hostname=host2
        """,
    )

    host1, _ = load_host_configs(cfg, repo_root)
    assert host1.key_path == key1.resolve()


def test_missing_key_file_errors(repo_root: Path) -> None:
    cfg = repo_root / "config.cfg"
    _write_cfg(
        cfg,
        """
        host1_ip=1.1.1.1
        host2_ip=2.2.2.2
        host1_key_path=keys/server1
        host2_key_path=keys/server2
        host1_ssh_hostname=host1
        host2_ssh_hostname=host2
        """,
    )

    with pytest.raises(ConfigError, match="key file does not exist"):
        load_host_configs(cfg, repo_root)
