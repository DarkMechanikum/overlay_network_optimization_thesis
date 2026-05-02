from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def persist_json_artifact(path: Path, payload: dict[str, Any]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return path


def register_existing_artifacts(paths: dict[str, str | None]) -> dict[str, str]:
    return {name: value for name, value in paths.items() if value}
