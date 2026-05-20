#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

"${SCRIPT_DIR}/sync_to_hosts.sh" "${CONFIG_FILE}"

for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
	log "Installing dependencies on ${host}"
	remote_bash "${host}" "bash -s" < "${SCRIPT_DIR}/install_deps.sh"
	log "Building ONCache on ${host}"
	remote "${host}" "bash '${REMOTE_SETUP_DIR}/scripts/build_oncache.sh' '${REMOTE_ONCACHE_DIR}'"
done

"${SCRIPT_DIR}/check_prerequisites.sh" "${CONFIG_FILE}"
