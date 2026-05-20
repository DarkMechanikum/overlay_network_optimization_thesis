#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
load_config "${CONFIG_FILE}"

"${SCRIPT_DIR}/init_submodules.sh"

for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	log "Syncing ONCache and setup scripts to ${host}"
	remote "${host}" "mkdir -p '${REMOTE_ONCACHE_DIR}' '${REMOTE_SETUP_DIR}'"
	rsync -az --delete \
		--exclude '.git/' \
		--exclude 'yaml-cpp/build/' \
		--exclude 'libbpf/src/libbpf.a' \
		--exclude 'libbpf/src/libbpf.so*' \
		--exclude 'libbpf/src/staticobjs/' \
		--exclude 'libbpf/src/sharedobjs/' \
		"${ONCACHE_SRC}/" "${host}:${REMOTE_ONCACHE_DIR}/"
	rsync -az "${SETUP_ROOT}/" "${host}:${REMOTE_SETUP_DIR}/"
done

log "Sync complete"
