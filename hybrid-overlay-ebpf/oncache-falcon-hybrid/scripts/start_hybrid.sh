#!/usr/bin/env bash
# Start the hybrid overlay datapath: ONCache cache fast path + Falcon-style
# multi-core fallback for cache misses and cold flows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYBRID_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HYBRID_OVERLAY_ROOT="$(cd "${HYBRID_ROOT}/.." && pwd)"

CONFIG_FILE="${1:-${HYBRID_OVERLAY_ROOT}/oncache-k8s/conf/oncache_k8s_setup.conf}"
FALCON_CONF="${2:-${HYBRID_ROOT}/conf/falcon_fallback.conf}"

"${HYBRID_OVERLAY_ROOT}/oncache-k8s/scripts/start_oncache.sh" "${CONFIG_FILE}"
"${SCRIPT_DIR}/apply_falcon_fallback.sh" "${CONFIG_FILE}" "${FALCON_CONF}"

echo "[hybrid] ONCache + Falcon-style fallback active"
