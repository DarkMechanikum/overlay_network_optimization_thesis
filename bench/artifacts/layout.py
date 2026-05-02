from __future__ import annotations

from pathlib import Path


def ensure_artifact_layout(repo_root: Path, run_id: str) -> dict[str, Path]:
    run_root = repo_root / "artifacts" / run_id
    local = run_root / "local"
    host1 = run_root / "host1"
    host2 = run_root / "host2"
    for path in (run_root, local, host1, host2):
        path.mkdir(parents=True, exist_ok=True)
    return {"run_root": run_root, "local": local, "host1": host1, "host2": host2}
