from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Callable, Generic, TypeVar

T = TypeVar("T")


@dataclass(frozen=True)
class PollResult(Generic[T]):
    values: list[T]
    attempts: int
    elapsed_seconds: float
    terminal_reason: str


def poll_with_interval(
    *,
    max_attempts: int,
    interval_s: float,
    check_fn: Callable[[], tuple[bool, T]],
    clock: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> PollResult[T]:
    values: list[T] = []
    attempts = 0
    started = clock()

    for idx in range(max_attempts):
        attempts += 1
        done, value = check_fn()
        values.append(value)
        if done:
            return PollResult(
                values=values,
                attempts=attempts,
                elapsed_seconds=max(0.0, clock() - started),
                terminal_reason="success",
            )
        if idx < max_attempts - 1:
            sleeper(interval_s)

    return PollResult(
        values=values,
        attempts=attempts,
        elapsed_seconds=max(0.0, clock() - started),
        terminal_reason="max_attempts_exhausted",
    )
