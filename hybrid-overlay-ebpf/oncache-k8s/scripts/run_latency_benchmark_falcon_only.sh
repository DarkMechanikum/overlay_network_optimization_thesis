#!/usr/bin/env bash
# Run only the Falcon-style multi-core fallback mode (no ONCache, no hybrid).
# Useful for isolating the contribution of RPS/XPS spreading from the cache
# fast path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BENCHMARK_MODES="baseline falcon"
export RESULT_ROOT="${RESULT_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)/results/k8s-latency-falcon}"

exec "${SCRIPT_DIR}/run_latency_benchmark.sh" "$@"
