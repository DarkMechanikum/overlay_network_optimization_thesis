from __future__ import annotations

import json
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from bench.config.loader import load_host_configs
from bench.context import BenchParams, RunContext, StageResult
from bench.runtime.failures import failure_payload
from bench.stages import (
    run_benchmark_stage,
    run_cleanup_stage,
    run_deploy_stage,
    run_metrics_stage,
    run_preflight_stage,
    run_results_stage,
    run_teardown_stage,
)


class StageExecutionTimeout(Exception):
    pass


def _new_run_context(repo_root: Path, config_path: Path, bench_params: BenchParams) -> RunContext:
    host1, host2 = load_host_configs(config_path=config_path, repo_root=repo_root)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    artifacts_root = repo_root / "artifacts" / run_id
    return RunContext(
        repo_root=repo_root,
        host1=host1,
        host2=host2,
        bench_params=bench_params,
        run_id=run_id,
        artifacts_root=artifacts_root,
    )


def run_pipeline(repo_root: Path, config_path: Path, bench_params: BenchParams) -> RunContext:
    ctx = _new_run_context(repo_root=repo_root, config_path=config_path, bench_params=bench_params)

    stages: list[tuple[str, Callable[[RunContext], StageResult]]] = [
        ("preflight", run_preflight_stage),
        ("cleanup", run_cleanup_stage),
        ("deploy", run_deploy_stage),
        ("benchmark", run_benchmark_stage),
        ("metrics", run_metrics_stage),
        ("results", run_results_stage),
    ]

    failed_stage = ""
    original_failure: StageResult | None = None
    try:
        for name, func in stages:
            _log("stage_start", stage=name, attempt=1)
            result = _run_stage_with_resilience(ctx, name, func)
            ctx.stage_results[name] = result
            if not result.success:
                failed_stage = name
                original_failure = result
                _log("stage_failure", stage=name, message=result.message)
                break
            _log("stage_end", stage=name, success=True)
    except KeyboardInterrupt:
        failed_stage = "orchestrator"
        original_failure = StageResult(
            success=False,
            message="Interrupted by user",
            payload=failure_payload("interrupted", "Interrupted by user", retryable=False),
        )
        ctx.stage_results["orchestrator"] = original_failure
        _log("stage_failure", stage="orchestrator", message="Interrupted by user")
    except Exception as exc:  # pragma: no cover - defensive
        failed_stage = "orchestrator"
        original_failure = StageResult(
            success=False,
            message=f"Unhandled exception: {exc}",
            payload=failure_payload(
                "exception",
                f"Unhandled exception: {exc}",
                retryable=False,
                exception_type=exc.__class__.__name__,
            ),
        )
        ctx.stage_results["orchestrator"] = original_failure
        _log("stage_failure", stage="orchestrator", message=str(exc))
    finally:
        teardown_reason = failed_stage or "success"
        teardown = run_teardown_stage(ctx, reason=teardown_reason)
        ctx.stage_results["teardown"] = teardown
        _log("teardown_end", stage="teardown", success=teardown.success, reason=teardown_reason)
        if original_failure is None and not teardown.success:
            # Teardown failure should not silently pass when pipeline succeeded.
            ctx.stage_results["teardown"] = teardown

    return ctx


def _run_stage_with_resilience(
    ctx: RunContext,
    stage_name: str,
    func: Callable[[RunContext], StageResult],
) -> StageResult:
    params = ctx.bench_params
    if params.dry_run:
        return StageResult(
            success=True,
            message=f"Dry-run: skipped stage {stage_name}",
            payload={"dry_run": True, "stage": stage_name, "planned": True},
        )

    attempts = params.retries + 1
    last_result = StageResult(success=False, message=f"{stage_name} did not execute")
    for attempt in range(1, attempts + 1):
        _log("stage_attempt", stage=stage_name, attempt=attempt, max_attempts=attempts)
        try:
            result = _run_stage_with_timeout(func, ctx, params.stage_timeout_seconds)
        except (TimeoutError, ConnectionError) as exc:
            result = StageResult(
                success=False,
                message=f"{stage_name} raised transient error: {exc}",
                payload=failure_payload(
                    "exception",
                    f"{stage_name} raised transient error: {exc}",
                    retryable=True,
                    exception_type=exc.__class__.__name__,
                ),
            )
        except StageExecutionTimeout:
            result = StageResult(
                success=False,
                message=f"{stage_name} timed out after {params.stage_timeout_seconds:.2f}s",
                payload=failure_payload(
                    "timeout",
                    f"{stage_name} timed out after {params.stage_timeout_seconds:.2f}s",
                    retryable=True,
                    timeout_seconds=params.stage_timeout_seconds,
                ),
            )
        except Exception as exc:
            return StageResult(
                success=False,
                message=f"{stage_name} raised non-retryable exception: {exc}",
                payload=failure_payload(
                    "exception",
                    f"{stage_name} raised non-retryable exception: {exc}",
                    retryable=False,
                    exception_type=exc.__class__.__name__,
                ),
            )

        if result.success:
            return result
        last_result = result
        retryable = _is_retryable(result)
        if not retryable or attempt >= attempts:
            return result
        if params.retry_backoff_seconds > 0:
            time.sleep(params.retry_backoff_seconds)
    return last_result


def _run_stage_with_timeout(
    func: Callable[[RunContext], StageResult], ctx: RunContext, timeout_seconds: float
) -> StageResult:
    output: dict[str, StageResult | BaseException] = {}

    def _target() -> None:
        try:
            output["result"] = func(ctx)
        except BaseException as exc:  # pragma: no cover - defensive
            output["error"] = exc

    thread = threading.Thread(target=_target, daemon=True)
    thread.start()
    thread.join(timeout=timeout_seconds)
    if thread.is_alive():
        raise StageExecutionTimeout()
    if "error" in output:
        raise output["error"]  # type: ignore[misc]
    return output["result"]  # type: ignore[return-value]


def _is_retryable(result: StageResult) -> bool:
    if "retryable" in result.payload:
        return bool(result.payload["retryable"])
    failure = result.payload.get("failure")
    if isinstance(failure, dict) and "retryable" in failure:
        return bool(failure["retryable"])
    return False


def _log(event: str, **kwargs: object) -> None:
    payload = {"event": event, **kwargs}
    print(json.dumps(payload, sort_keys=True))
