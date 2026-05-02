from __future__ import annotations

import argparse
import json
from pathlib import Path

from bench.config.validation import ValidatedRunParams, ValidationError
from bench.orchestrator import run_pipeline


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Overlay benchmark orchestrator")
    parser.add_argument("--config", default="config.cfg", help="Path to config.cfg")
    parser.add_argument("--connections", type=int, default=10)
    parser.add_argument("--duration-seconds", type=int, default=30)
    parser.add_argument("--warmup-seconds", type=int, default=3)
    parser.add_argument("--cooldown-seconds", type=int, default=2)
    parser.add_argument("--base-pps", type=int, default=1000)
    parser.add_argument("--packet-size", type=int, default=128)
    parser.add_argument("--ssh-timeout-seconds", type=float, default=10.0)
    parser.add_argument("--cleanup-mode", choices=("safe", "full"), default="safe")
    parser.add_argument(
        "--confirm-full-cleanup",
        action="store_true",
        help="Required to allow destructive --cleanup-mode full",
    )
    parser.add_argument("--host-temp-root", default="/tmp/bench-run")
    parser.add_argument("--disk-warn-percent", type=int, default=85)
    parser.add_argument("--memory-warn-mb", type=int, default=1024)
    parser.add_argument("--deployment-mode", choices=("remote-build", "transfer"), default="remote-build")
    parser.add_argument("--readiness-timeout-seconds", type=float, default=30.0)
    parser.add_argument("--readiness-poll-interval-seconds", type=float, default=2.0)
    parser.add_argument("--image-tag", default="overlay-bench:latest")
    parser.add_argument("--local-image-archive", default="/tmp/overlay-bench-image.tar")
    parser.add_argument("--container-network-mode", default="host")
    parser.add_argument("--src-port-start", type=int, default=20000)
    parser.add_argument("--dst-port-start", type=int, default=30000)
    parser.add_argument("--max-port", type=int, default=60999)
    parser.add_argument("--flow-startup-timeout-seconds", type=float, default=15.0)
    parser.add_argument("--flow-startup-poll-interval-seconds", type=float, default=1.0)
    parser.add_argument("--retries", type=int, default=0)
    parser.add_argument("--timeout", type=float, default=120.0, help="Per-stage orchestration timeout in seconds")
    parser.add_argument("--keep-containers", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--fallback-runtime-image", default="python:3.11-slim")
    parser.add_argument(
        "--cpu-window-seconds",
        type=float,
        default=0.01,
        help="CPU metrics: time-bin width (s); per-bin top/bottom/CV are averaged across bins",
    )
    parser.add_argument(
        "--allow-synthetic-telemetry",
        action="store_true",
        help="Allow synthetic telemetry fallback when runtime telemetry is missing",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        params = ValidatedRunParams.from_namespace(args).to_bench_params()
    except ValidationError as exc:
        print(f"Parameter validation failed: {exc}")
        return 2
    repo_root = Path.cwd()
    ctx = run_pipeline(
        repo_root=repo_root,
        config_path=Path(args.config),
        bench_params=params,
    )
    results = ctx.stage_results.get("results")
    if results and results.payload:
        if results.payload.get("result_csv_path"):
            print(f"Result CSV: {results.payload['result_csv_path']}")
        if results.payload.get("artifact_run_dir"):
            print(f"Artifacts: {results.payload['artifact_run_dir']}")
    failed_stage, failed_result = _first_failure(ctx.stage_results)
    if failed_result is not None:
        hint = _failure_hint(failed_stage, failed_result.message)
        print(f"FAILED stage: {failed_stage}")
        print(f"Reason: {failed_result.message}")
        if failed_result.payload:
            print("Failure payload:")
            print(json.dumps(failed_result.payload, indent=2, sort_keys=True, default=str))
        if hint:
            print(f"Hint: {hint}")
        return 2
    return 0


def _first_failure(stage_results):
    for name, result in stage_results.items():
        if not result.success:
            return name, result
    return "", None


def _failure_hint(stage_name: str, message: str) -> str:
    lower = message.lower()
    if "timeout" in lower:
        return "Increase --timeout or reduce workload for this run."
    if "ssh" in lower or "connection" in lower:
        return "Verify SSH hostnames/keys and network reachability from config.cfg."
    if "docker" in lower:
        return "Verify Docker daemon health on both hosts."
    if "missing" in lower or "dependency" in lower:
        return "Run preflight and install required dependencies on both hosts."
    if stage_name == "results":
        return "Inspect validation errors in results stage payload and artifact manifest."
    return ""


if __name__ == "__main__":
    raise SystemExit(main())
