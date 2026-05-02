from __future__ import annotations

import csv
import json
import os
from pathlib import Path

import pytest


REQUIRED_CSV_COLUMNS = {
    "run_id",
    "flow_id",
    "pps",
    "latency_p50",
    "latency_p99",
    "latency_p999",
    "sender_cpu_avg",
    "receiver_cpu_avg",
    "sender_cpu_core_cv",
    "receiver_cpu_core_cv",
    "sender_cpu_top_core_utilization",
    "receiver_cpu_top_core_utilization",
    "sender_cpu_bottom_core_utilization",
    "receiver_cpu_bottom_core_utilization",
    "status",
}


def _repo_root_from_here() -> Path:
    return Path(__file__).resolve().parents[2]


@pytest.fixture(scope="session")
def integration_repo_root() -> Path:
    return _repo_root_from_here()


@pytest.fixture(scope="session")
def integration_config_path() -> Path:
    if os.getenv("RUN_INTEGRATION") != "1":
        pytest.skip("Integration tests are disabled. Set RUN_INTEGRATION=1 to enable.")
    sample_path = _repo_root_from_here() / "tests" / "integration" / "config.sample.cfg"
    configured = os.getenv("INTEGRATION_CONFIG_PATH")
    if not configured:
        pytest.skip(
            "INTEGRATION_CONFIG_PATH is required for real-host integration tests. "
            f"Start from sample: {sample_path}"
        )
    path = Path(configured).expanduser().resolve()
    if not path.exists():
        pytest.skip(f"INTEGRATION_CONFIG_PATH does not exist: {path}")
    return path


def parse_cli_paths(stdout: str) -> tuple[Path | None, Path | None]:
    result_csv = None
    artifact_dir = None
    for line in stdout.splitlines():
        if line.startswith("Result CSV:"):
            result_csv = Path(line.split(":", 1)[1].strip())
        elif line.startswith("Artifacts:"):
            artifact_dir = Path(line.split(":", 1)[1].strip())
    return result_csv, artifact_dir


def validate_csv_file(path: Path) -> list[dict[str, str]]:
    assert path.exists(), f"CSV file does not exist: {path}"
    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        assert reader.fieldnames is not None, "CSV header is missing"
        missing = REQUIRED_CSV_COLUMNS - set(reader.fieldnames)
        assert not missing, f"CSV missing required columns: {sorted(missing)}"
        rows = list(reader)
    assert len(rows) > 0, "CSV must contain at least one data row"
    return rows


def validate_manifest(path: Path) -> dict[str, object]:
    assert path.exists(), f"Manifest file does not exist: {path}"
    raw = json.loads(path.read_text(encoding="utf-8"))
    for key in ("run_id", "params", "artifact_paths", "result_csv_path", "synthetic_metrics", "telemetry_source"):
        assert key in raw, f"Manifest missing required key: {key}"
    return raw


def validate_artifact_layout(artifact_dir: Path) -> None:
    assert artifact_dir.exists(), f"Artifact directory does not exist: {artifact_dir}"
    for sub in ("local", "host1", "host2"):
        assert (artifact_dir / sub).exists(), f"Missing artifact subdirectory: {sub}"
    assert (artifact_dir / "run.json").exists(), "Expected run.json in artifact directory"


def validate_windowed_cpu_metrics(artifact_dir: Path, csv_rows: list[dict[str, str]]) -> None:
    normalized_metrics = artifact_dir / "local" / "normalized-metrics.json"
    assert normalized_metrics.exists(), f"Expected normalized metrics artifact: {normalized_metrics}"
    payload = json.loads(normalized_metrics.read_text(encoding="utf-8"))
    cpu_summaries = payload.get("cpu_summaries", {})
    for role in ("host1", "host2"):
        summary = cpu_summaries.get(role)
        assert isinstance(summary, dict), f"Missing cpu summary for {role}"
        if summary.get("status") != "ok":
            continue
        avg = summary.get("avg_utilization_percent")
        top = summary.get("top_core_utilization_percent")
        bottom = summary.get("bottom_core_utilization_percent")
        cv = summary.get("core_util_cv")
        assert avg is not None, f"Expected avg util for {role}"
        assert top is not None, f"Expected top util for {role}"
        assert bottom is not None, f"Expected bottom util for {role}"
        assert cv is not None, f"Expected core CV for {role}"
        assert top >= bottom, f"Expected top>=bottom for {role}"
        assert 0.0 <= avg <= 100.0, f"Expected avg util in [0,100] for {role}"
        assert cv >= 0.0, f"Expected non-negative CV for {role}"

    for row in csv_rows:
        if row.get("status") != "ok":
            continue
        for key in (
            "sender_cpu_avg",
            "receiver_cpu_avg",
            "sender_cpu_core_cv",
            "receiver_cpu_core_cv",
            "sender_cpu_top_core_utilization",
            "receiver_cpu_top_core_utilization",
            "sender_cpu_bottom_core_utilization",
            "receiver_cpu_bottom_core_utilization",
        ):
            assert row.get(key, "") not in ("", None), f"Expected populated {key} for ok row"


def assert_no_synthetic_telemetry(manifest: dict[str, object]) -> None:
    assert manifest.get("synthetic_metrics") is False, "Real-host smoke run must not use synthetic telemetry"
    assert manifest.get("telemetry_source") == "runtime", "Expected runtime telemetry source for smoke run"
