#!/usr/bin/env bash
# Baseline vs ONCache with low MTU + many NetworkPolicies (primary stress benchmark).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OVERLAY_STRESS_ENABLE=1
export RESULT_ROOT="${RESULT_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)/results/k8s-latency-overlay-stress}"

exec "${SCRIPT_DIR}/run_latency_benchmark.sh" "$@"
