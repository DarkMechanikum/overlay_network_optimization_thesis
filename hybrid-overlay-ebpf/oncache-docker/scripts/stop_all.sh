#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_real_setup.conf}"
load_config "${CONFIG_FILE}"

stop_host() {
	local host="$1"
	local node_ifname="$2"
	local container="$3"
	log "Stopping ONCache on ${host}"
	remote_bash "${host}" <<EOF
set -euo pipefail
pkill -f docker_daemon.py 2>/dev/null || true
bash "${REMOTE_SETUP_DIR}/scripts/stop_oncache.sh" "${REMOTE_ONCACHE_DIR}" "${node_ifname}" "${container}" eth0 || true
EOF
}

stop_host "${SERVER_HOST}" "${SERVER_NODE_IFNAME}" "${SERVER_CONTAINER}"
stop_host "${CLIENT_HOST}" "${CLIENT_NODE_IFNAME}" "${CLIENT_CONTAINER}"
