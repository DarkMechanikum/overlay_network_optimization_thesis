from __future__ import annotations

from pathlib import Path

from bench.results.paths import ensure_results_dir, resolve_indexed_result_csv


def test_indexing_empty_dir_uses_result_csv(tmp_path: Path) -> None:
    results = ensure_results_dir(tmp_path)
    assert resolve_indexed_result_csv(results).name == "result.csv"


def test_indexing_after_existing_base_file(tmp_path: Path) -> None:
    results = ensure_results_dir(tmp_path)
    (results / "result.csv").write_text("x", encoding="utf-8")
    assert resolve_indexed_result_csv(results).name == "result-1.csv"


def test_indexing_uses_next_available_suffix_and_never_overwrites(tmp_path: Path) -> None:
    results = ensure_results_dir(tmp_path)
    for name in ("result.csv", "result-1.csv", "result-2.csv"):
        (results / name).write_text("taken", encoding="utf-8")
    candidate = resolve_indexed_result_csv(results)
    assert candidate.name == "result-3.csv"
    assert not candidate.exists()
