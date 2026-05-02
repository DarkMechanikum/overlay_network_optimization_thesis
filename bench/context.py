from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class HostConfig:
    role: str
    ip: str
    ssh_hostname: str
    key_path: Path


@dataclass(frozen=True)
class BenchParams:
    connections: int = 10
    duration_seconds: int = 30
    warmup_seconds: int = 3
    cooldown_seconds: int = 2
    base_pps: int = 1000
    packet_size: int = 128
    ssh_timeout_seconds: float = 10.0
    cleanup_mode: str = "safe"
    confirm_full_cleanup: bool = False
    host_temp_root: str = "/tmp/bench-run"
    disk_warn_percent: int = 85
    memory_warn_mb: int = 1024
    deployment_mode: str = "remote-build"
    readiness_timeout_seconds: float = 30.0
    readiness_poll_interval_seconds: float = 2.0
    image_tag: str = "overlay-bench:latest"
    local_image_archive: str = "/tmp/overlay-bench-image.tar"
    container_network_mode: str = "host"
    src_port_start: int = 20000
    dst_port_start: int = 30000
    max_port: int = 60999
    flow_startup_timeout_seconds: float = 15.0
    flow_startup_poll_interval_seconds: float = 1.0
    retries: int = 0
    retry_backoff_seconds: float = 0.0
    stage_timeout_seconds: float = 120.0
    keep_containers: bool = False
    dry_run: bool = False
    fallback_runtime_image: str = "python:3.11-slim"
    # Bin CPU samples into windows (seconds); per-window top/bottom/CV then averaged across windows.
    cpu_window_seconds: float = 0.01
    allow_synthetic_telemetry: bool = False


@dataclass
class StageResult:
    success: bool
    message: str = ""
    payload: dict[str, Any] = field(default_factory=dict)


@dataclass
class RunContext:
    repo_root: Path
    host1: HostConfig
    host2: HostConfig
    bench_params: BenchParams
    run_id: str
    artifacts_root: Path
    stage_results: dict[str, StageResult] = field(default_factory=dict)
