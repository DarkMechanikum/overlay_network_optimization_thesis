from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

from .conftest import (
    assert_no_synthetic_telemetry,
    parse_cli_paths,
    validate_artifact_layout,
    validate_csv_file,
    validate_manifest,
    validate_windowed_cpu_metrics,
)


@pytest.mark.integration
def test_functional_smoke_real_hosts(
    integration_repo_root: Path,
    integration_config_path: Path,
) -> None:
    command = [
        sys.executable,
        "-m",
        "bench.cli",
        "--config",
        str(integration_config_path),
        "--connections",
        "2",
        "--duration-seconds",
        "6",
        "--warmup-seconds",
        "1",
        "--cooldown-seconds",
        "1",
        "--base-pps",
        "50",
        "--packet-size",
        "128",
        "--cleanup-mode",
        "safe",
        "--retries",
        "1",
        "--timeout",
        "120",
    ]
    completed = subprocess.run(
        command,
        cwd=integration_repo_root,
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0, (
        "Functional smoke CLI invocation failed.\n"
        f"stdout:\n{completed.stdout}\n\nstderr:\n{completed.stderr}"
    )

    result_csv, artifact_dir = parse_cli_paths(completed.stdout)
    assert result_csv is not None, "CLI did not print final result CSV path"
    assert artifact_dir is not None, "CLI did not print artifact directory path"

    rows = validate_csv_file(result_csv)
    validate_artifact_layout(artifact_dir)
    manifest = validate_manifest(artifact_dir / "run.json")
    validate_windowed_cpu_metrics(artifact_dir, rows)
    assert_no_synthetic_telemetry(manifest)
    assert Path(manifest["result_csv_path"]).resolve() == result_csv.resolve()
