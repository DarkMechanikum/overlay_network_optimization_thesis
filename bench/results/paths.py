from __future__ import annotations

from pathlib import Path


def ensure_results_dir(repo_root: Path) -> Path:
    results_dir = repo_root / "results"
    results_dir.mkdir(parents=True, exist_ok=True)
    return results_dir


def resolve_indexed_result_csv(results_dir: Path, base_name: str = "result.csv") -> Path:
    results_dir.mkdir(parents=True, exist_ok=True)
    base_path = results_dir / base_name
    if not base_path.exists():
        return base_path

    stem = base_path.stem
    suffix = base_path.suffix
    index = 1
    while True:
        candidate = results_dir / f"{stem}-{index}{suffix}"
        if not candidate.exists():
            return candidate
        index += 1
