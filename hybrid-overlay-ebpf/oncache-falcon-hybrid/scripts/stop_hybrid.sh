#!/usr/bin/env bash
# Tear down the hybrid overlay datapath: revert Falcon-style fallback, then
# stop ONCache. Always best-effort so it composes with the benchmark teardown.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYBRID_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HYBRID_OVERLAY_ROOT="$(cd "${HYBRID_ROOT}/.." && pwd)"

CONFIG_FILE="${1:-${HYBRID_OVERLAY_ROOT}/oncache-k8s/conf/oncache_k8s_setup.conf}"
FALCON_CONF="${2:-${HYBRID_ROOT}/conf/falcon_fallback.conf}"

"${SCRIPT_DIR}/revert_falcon_fallback.sh" "${CONFIG_FILE}" "${FALCON_CONF}" || true
"${HYBRID_OVERLAY_ROOT}/oncache-k8s/scripts/stop_oncache.sh" "${CONFIG_FILE}" || true

echo "[hybrid] stopped"
