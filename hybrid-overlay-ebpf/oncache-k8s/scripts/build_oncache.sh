#!/usr/bin/env bash
# Build upstream ONCache (no SWARM_* flags) for Kubernetes + Antrea.
set -euo pipefail

ONCACHE_DIR="${1:?Usage: $0 <oncache-source-dir>}"

if [[ ! -d "${ONCACHE_DIR}" ]]; then
	echo "ONCache source directory not found: ${ONCACHE_DIR}" >&2
	exit 1
fi

rm -rf "${ONCACHE_DIR}/yaml-cpp/build"
make -C "${ONCACHE_DIR}" all EXTRA_CFLAGS="-Wno-error=unused-but-set-variable -DONCACHE_K8S_ANTREA"
echo "Built ONCache in ${ONCACHE_DIR} (upstream K8s/Antrea flags)"
