from __future__ import annotations

from bench.runtime.polling import poll_with_interval


def test_poll_with_interval_sleeps_between_attempts_until_success() -> None:
    sleeps: list[float] = []
    attempts = {"n": 0}
    now = {"t": 0.0}

    def _clock() -> float:
        return now["t"]

    def _sleep(seconds: float) -> None:
        sleeps.append(seconds)
        now["t"] += seconds

    def _check() -> tuple[bool, int]:
        attempts["n"] += 1
        return (attempts["n"] == 3, attempts["n"])

    result = poll_with_interval(max_attempts=5, interval_s=0.5, check_fn=_check, clock=_clock, sleeper=_sleep)
    assert result.terminal_reason == "success"
    assert result.attempts == 3
    assert result.values == [1, 2, 3]
    assert sleeps == [0.5, 0.5]


def test_poll_with_interval_does_not_sleep_after_last_attempt() -> None:
    sleeps: list[float] = []

    def _check() -> tuple[bool, int]:
        return False, 0

    result = poll_with_interval(max_attempts=2, interval_s=1.0, check_fn=_check, sleeper=sleeps.append)
    assert result.terminal_reason == "max_attempts_exhausted"
    assert result.attempts == 2
    assert sleeps == [1.0]
