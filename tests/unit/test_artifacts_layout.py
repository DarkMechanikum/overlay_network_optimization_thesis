from __future__ import annotations

from pathlib import Path

from bench.artifacts.layout import ensure_artifact_layout


def test_artifact_layout_creation_is_idempotent(tmp_path: Path) -> None:
    first = ensure_artifact_layout(tmp_path, "run1")
    second = ensure_artifact_layout(tmp_path, "run1")
    assert first["run_root"].exists()
    assert first["local"].exists()
    assert first["host1"].exists()
    assert first["host2"].exists()
    assert first["run_root"] == second["run_root"]
