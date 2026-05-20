#!/usr/bin/env bash
# Baseline vs ONCache with synthetic CPU load (stress-ng) on both nodes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CPU_STRESS_ENABLE=1
export RESULT_ROOT="${RESULT_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)/results/k8s-latency-cpu-stress}"

exec "${SCRIPT_DIR}/run_latency_benchmark.sh" "$@"
