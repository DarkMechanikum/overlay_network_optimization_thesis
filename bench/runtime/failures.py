from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any


@dataclass(frozen=True)
class StageFailure:
    kind: str
    message: str
    retryable: bool
    details: dict[str, Any] = field(default_factory=dict)

    def to_payload(self) -> dict[str, Any]:
        return {"failure": asdict(self), "retryable": self.retryable}


def failure_payload(kind: str, message: str, *, retryable: bool, **details: Any) -> dict[str, Any]:
    return StageFailure(kind=kind, message=message, retryable=retryable, details=details).to_payload()
