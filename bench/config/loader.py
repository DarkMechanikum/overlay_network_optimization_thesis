from __future__ import annotations

import os
from pathlib import Path

from bench.context import HostConfig


REQUIRED_KEYS = (
    "host1_ip",
    "host2_ip",
    "host1_key_path",
    "host2_key_path",
    "host1_ssh_hostname",
    "host2_ssh_hostname",
)


class ConfigError(ValueError):
    """Raised when config.cfg is invalid."""


def _parse_key_values(config_path: Path) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for raw_line in config_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ConfigError(f"Invalid config line (expected key=value): {raw_line}")
        key, value = line.split("=", 1)
        parsed[key.strip()] = value.strip()
    return parsed


def _require_non_empty(data: dict[str, str], key: str) -> str:
    value = data.get(key, "")
    if not value:
        raise ConfigError(f"Missing required config key: {key}")
    return value


def _resolve_key_path(repo_root: Path, key_path_value: str, host_label: str) -> Path:
    raw_path = Path(key_path_value)
    resolved = (repo_root / raw_path).resolve() if not raw_path.is_absolute() else raw_path.resolve()
    if not resolved.exists():
        raise ConfigError(f"{host_label} key file does not exist: {resolved}")
    if not resolved.is_file():
        raise ConfigError(f"{host_label} key path is not a file: {resolved}")
    if not os.access(resolved, os.R_OK):
        raise ConfigError(f"{host_label} key path is not readable: {resolved}")
    return resolved


def load_host_configs(config_path: Path, repo_root: Path) -> tuple[HostConfig, HostConfig]:
    data = _parse_key_values(config_path)
    for key in REQUIRED_KEYS:
        _require_non_empty(data, key)

    host1 = HostConfig(
        role="host1",
        ip=data["host1_ip"],
        ssh_hostname=data["host1_ssh_hostname"],
        key_path=_resolve_key_path(repo_root, data["host1_key_path"], "host1"),
    )
    host2 = HostConfig(
        role="host2",
        ip=data["host2_ip"],
        ssh_hostname=data["host2_ssh_hostname"],
        key_path=_resolve_key_path(repo_root, data["host2_key_path"], "host2"),
    )
    return host1, host2
