from __future__ import annotations

import argparse

import pytest

from bench.config.validation import ValidatedRunParams, ValidationError


def _args(**overrides: object) -> argparse.Namespace:
    data: dict[str, object] = {
        "connections": 10,
        "duration_seconds": 30,
        "warmup_seconds": 3,
        "cooldown_seconds": 2,
        "base_pps": 1000,
        "packet_size": 128,
        "ssh_timeout_seconds": 10.0,
        "cleanup_mode": "safe",
        "confirm_full_cleanup": False,
        "host_temp_root": "/tmp/bench-run",
        "disk_warn_percent": 85,
        "memory_warn_mb": 1024,
        "deployment_mode": "remote-build",
        "readiness_timeout_seconds": 30.0,
        "readiness_poll_interval_seconds": 2.0,
        "image_tag": "overlay-bench:latest",
        "local_image_archive": "/tmp/overlay-bench-image.tar",
        "container_network_mode": "host",
        "src_port_start": 20000,
        "dst_port_start": 30000,
        "max_port": 60999,
        "flow_startup_timeout_seconds": 15.0,
        "flow_startup_poll_interval_seconds": 1.0,
        "retries": 1,
        "retry_backoff_seconds": 0.5,
        "timeout": 120.0,
        "keep_containers": False,
        "dry_run": False,
        "fallback_runtime_image": "python:3.11-slim",
        "cpu_window_seconds": 0.01,
        "allow_synthetic_telemetry": False,
    }
    data.update(overrides)
    return argparse.Namespace(**data)


def test_validated_run_params_accepts_valid_matrix() -> None:
    validated = ValidatedRunParams.from_namespace(_args())
    params = validated.to_bench_params()
    assert params.duration_seconds == 30
    assert params.warmup_seconds == 3
    assert params.cooldown_seconds == 2
    assert params.stage_timeout_seconds == 120.0
    assert params.cpu_window_seconds == 0.01


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("retries", -1),
        ("timeout", 0.0),
        ("readiness_poll_interval_seconds", 0.0),
        ("flow_startup_poll_interval_seconds", -0.1),
        ("cpu_window_seconds", 0.0),
    ],
)
def test_validated_run_params_rejects_invalid_bounds(field: str, value: int | float) -> None:
    with pytest.raises(ValidationError) as exc:
        ValidatedRunParams.from_namespace(_args(**{field: value}))
    assert exc.value.field in {field, "timeout"}


def test_validated_run_params_rejects_invalid_measurement_window() -> None:
    with pytest.raises(ValidationError) as exc:
        ValidatedRunParams.from_namespace(_args(duration_seconds=4, warmup_seconds=2, cooldown_seconds=2))
    assert exc.value.field == "duration_seconds"
    assert "warmup_seconds + cooldown_seconds" in str(exc.value)


def test_validated_run_params_rejects_telemetry_policy_related_bounds() -> None:
    with pytest.raises(ValidationError) as exc:
        ValidatedRunParams.from_namespace(_args(cpu_window_seconds=-0.01))
    assert exc.value.field == "cpu_window_seconds"
